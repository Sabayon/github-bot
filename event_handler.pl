#!/usr/bin/perl

use Mojolicious::Lite;
use Mojo::JSON qw(decode_json encode_json);
use Net::GitHub;
use Mojolicious::Plugin::Minion;
use Mojolicious::Plugin::Directory;
use Minion::Backend::Storable;
use Minion;
use Mojolicious::Plugin::AssetPack;
use IPC::Open3;
use Storable qw(lock_store lock_nstore lock_retrieve);
use Git::Sub qw(clone tag push);
use Mojo::File qw(tempdir path);
use Cwd;
use Data::Dumper;

use constant DEBUG => $ENV{DEBUG} // 0;
use constant GH_TOKEN     => $ENV{GH_TOKEN};
use constant CONTEXT      => $ENV{GH_CONTEXT} || "package build";
use constant BASE_URL     => $ENV{BASE_URL};
use constant WORKDIR      => $ENV{WORK_DIRECTORY} || cwd;
use constant MINION_DATA  => $ENV{MINION_DATA} || "minion.data";
use constant SHARED_DATA  => $ENV{SHARED_DATA} || "shared_data";
use constant BUILD_SCRIPT => $ENV{BUILD_SCRIPT} || "./test_ci.sh";
use constant MESSAGE_FILE => $ENV{MESSAGE_FILE} || "MESSAGE";
use constant FA_URL       => $ENV{FA_URL};

use constant ROOTDIR_STATIC_FILES => $ENV{ROOTDIR_STATIC_FILES}
    || join( "/", WORKDIR, "static" );
use constant ARTIFACTS_FOLDER => $ENV{ARTIFACTS_FOLDER} || "artifacts";

use constant GH_ALLOWED_USERS    => $ENV{GH_ALLOWED_USERS};
use constant GH_ALLOWED_REPOS    => $ENV{GH_ALLOWED_REPOS};
use constant PUBLIC              => $ENV{PUBLIC} // 1;
use constant AUTOINDEX_ARTIFACTS => $ENV{AUTOINDEX} || 0;

use constant PAGE_TITLE => $ENV{PAGE_TITLE} || "Sabayon buildbot";

die "You need to pass GH_TOKEN by env"
    unless GH_TOKEN;

my @failure_messages = (
    "Ufff. :confused: it seems your PR failed passing build phase :disappointed:",
    "MAYDAY, MAYDAY, MAYDAY :confounded: something is failing here!",
    ":no_good:"
);
my @success_messages = (
    "All fine here! :bowtie:", "We have a winner! :sunglasses:",
    ":+1:",                    ":ok_hand:"
);
my @pending_messages = ( ":fire: Working on it", ":running:" );

my %allowed_repo;
my %allowed_users;

@allowed_repo{ split( /\s/, GH_ALLOWED_REPOS ) }++ if !!GH_ALLOWED_REPOS;
@allowed_users{ split( /\s/, GH_ALLOWED_USERS ) }++ if !!GH_ALLOWED_USERS;

# Could be feeded to plugin Directory, but i don't see the reason to load it if we do not need it
if (AUTOINDEX_ARTIFACTS) {
    plugin Directory => { root => path(ROOTDIR_STATIC_FILES)->make_path };
}
else {
    app->static->paths->[0] = path(ROOTDIR_STATIC_FILES)->make_path;
}

plugin AssetPack => { pipes => [qw(Css JavaScript)] };

plugin Minion => { Storable => path( WORKDIR, MINION_DATA ) };

app->asset->process(
    'app.css' => (
        'https://maxcdn.bootstrapcdn.com/bootstrap/3.3.7/css/bootstrap.min.css',
        'https://maxcdn.bootstrapcdn.com/bootstrap/3.3.7/css/bootstrap-theme.min.css',
    )
);
app->asset->process(
    'app.js' => (
        'https://code.jquery.com/jquery-3.2.1.min.js',
        'https://maxcdn.bootstrapcdn.com/bootstrap/3.3.7/js/bootstrap.min.js',
        'https://raw.githubusercontent.com/drudru/ansi_up/master/ansi_up.js',
        (FA_URL) x !!(FA_URL)
    )
);

app->defaults( title => PAGE_TITLE );
app->log->level( DEBUG ? 'debug' : 'info' );

# Main task that execute our custom BUILD_SCRIPT
app->minion->add_task(
    build_repo => sub {
        my ( $job, $payload, $event_type ) = @_;

        my $current_dir = cwd;

        my $sha      = $payload->{$event_type}->{head}->{sha};
        my $base_sha = $payload->{$event_type}->{base}->{sha};

        my $patch_url = $payload->{$event_type}->{patch_url};
        my $pr_number = $payload->{$event_type}->{number};
        my $git_url   = $payload->{$event_type}->{base}->{repo}->{clone_url};
        my $git_repo  = $payload->{$event_type}->{base}->{repo}->{name};
        my $git_repo_user =
            $payload->{$event_type}->{base}->{repo}->{owner}->{login};
        my $details_msg =
            BASE_URL
            ? " - check out the [details](" . BASE_URL . "/build/$sha)"
            : " - Don't bother searching a detail url, i don't have it for you";

        return
            unless PUBLIC
            || ( $allowed_users{$git_repo_user} && $allowed_repo{$git_repo} );

        $job->app->log->info(
            "Event: $event_type SHA: $sha [PR#$pr_number] - Build received");

        my $github = Net::GitHub->new( access_token => GH_TOKEN )
            or $job->app->log->debug("Could not create Net::GitHub object");

        $github->set_default_user_repo( $git_repo_user, $git_repo );

        my $repos  = $github->repos;
        my $issues = $github->issue;

        my @statuses = $repos->list_statuses($sha);

        # # Don't run if some other worker picked up the job
        return
               if @statuses > 0
            && $statuses[0]->{context} eq CONTEXT
            && $statuses[0]->{state} eq "pending";

        # XXX: Security, Return also if changed file is just the BUILD_SCRIPT
        $job->app->log->info(
            "Event: $event_type SHA: $sha [PR#$pr_number] - Build start");
        my %shared_data;

        # update github status.
        my $status = $repos->create_status(
            $sha,
            {   "state" => "pending",
                ( "target_url" => BASE_URL . "/build/$sha" ) x !!(BASE_URL),
                "context" => CONTEXT
            }
        );

        $shared_data{$sha}{gh_state}   = "pending";
        $shared_data{$sha}{status}     = "building";
        $shared_data{$sha}{start_time} = time;

        lock_store \%shared_data, path( WORKDIR, SHARED_DATA );

        # Create a comment to tell the user that we are working on it.
        my $comment = $issues->create_comment(
            $pr_number,
            {   body => $pending_messages[ rand @pending_messages ]
                    . $details_msg
            }
        );

        # Execute the build.
        # Passing the github data into the process STDIN
        my @output;
        my $return;
        my $script       = BUILD_SCRIPT;
        my $json_payload = encode_json $payload->{$event_type};
        my $workdir      = tempdir;

        $job->app->log->debug("Working on $workdir");

        chdir($workdir);
        git::clone $git_url;
        my $build_dir = path( $workdir, $git_repo );

        chdir($build_dir) if -d $build_dir;
        $job->app->log->debug("Fetching PR in $build_dir");

        git::fetch "origin", "pull/$pr_number/head:CI_test";
        git::checkout "CI_test";

        local $ENV{GH_USER}          = $git_repo_user;
        local $ENV{GH_REPO}          = $git_repo;
        local $ENV{BASE_SHA}         = $base_sha;
        local $ENV{SHA}              = $sha;
        local $ENV{PATCH_URL}        = $patch_url;
        local $ENV{PR_NUMBER}        = $pr_number;
        local $ENV{ARTIFACTS_FOLDER} = ARTIFACTS_FOLDER;
        local $ENV{MESSAGE_FILE}     = MESSAGE_FILE;
        local $ENV{GH_TOKEN};

        $job->app->log->debug( "Exposed environment " . `env` );
        system("chmod +x $script") if -e $script;
        eval {
            @output =
                qx(echo '$json_payload' | $script $git_repo_user $git_repo $base_sha $sha $patch_url $pr_number 2>&1);
            $return = $?;
        };
        $shared_data{$sha}{error} = $@ and $return = 1
            if $@;    # Collect (might-be) errors

        chdir($current_dir);
        $job->app->log->debug("Checking for artifacts in $current_dir");

        my $asset = path( $build_dir, ARTIFACTS_FOLDER );
        if ( -d $asset ) {
            $job->app->log->debug("Found asset: $asset");
            my $dest = path( ROOTDIR_STATIC_FILES, $sha )->make_path;
            $job->app->log->debug("Copying $asset to $dest");
            system("cp -rfv $asset $dest");

# this makes /sha/ARTIFACTS_FOLDER accessible as static. (e.g. /a2cb1/artifacts )
            $shared_data{$sha}{asset}     = $dest->to_string;
            $shared_data{$sha}{asset_url} = BASE_URL . "/$sha/artifacts";

# this makes /sha/ARTIFACTS_FOLDER accessible as static. (e.g. /a2cb1/artifacts )
#$shared_data{$sha}{asset} = $asset->copy_to(path(ROOTDIR_STATIC_FILES,$sha)->make_path)->to_string;
        }

        # we got a message?
        my $msg = path( $build_dir, ARTIFACTS_FOLDER, MESSAGE_FILE );
        if ( -e $msg ) {
            $shared_data{$sha}{message} = $msg->slurp;
            $details_msg .= " " . $shared_data{$sha}{message};

            $job->app->log->debug(
                "Build message: " . $shared_data{$sha}{message} );
        }

        $job->app->log->debug("Cleanup $workdir");
        path($workdir)->remove_tree;

        my $state = $return != 0 ? "failure" : "success";

        $shared_data{$sha}{return}      = $return;
        $shared_data{$sha}{exit_status} = $return >> 8;
        $shared_data{$sha}{status}      = $state;
        $shared_data{$sha}{output}      = \@output;
        my $msg =
              $state eq "failure"
            ? $failure_messages[ rand @failure_messages ]
            : $success_messages[ rand @success_messages ];
        $job->app->log->debug( "Saved build status for '$sha' : "
                . Dumper( $shared_data{$sha} ) );

        # Update comment to reflect build status.
        $comment = $issues->update_comment( $comment->{id},
            { body => $msg . $details_msg } );

        # Update the GH status relative to the SHA
        $status = $repos->create_status(
            $sha,
            {   "state" => $state,
                ( "target_url" => BASE_URL . "/build/$sha" ) x !!(BASE_URL),
                "description" => $state eq "success"
                ? "Successful build"
                : "Build failed",
                "context" => CONTEXT
            }
        );

        lock_store \%shared_data, path( WORKDIR, SHARED_DATA );

        $job->app->log->debug(
            "Event: $event_type SHA: $sha [PR#$pr_number] $state - Build finished"
        );
    }
);

helper build_data => sub {
    my $cb = pop;
    my ( $c, $id ) = @_;
    my $shared_data;
    local ( $!, $@ );
    eval { $shared_data = lock_retrieve( path( WORKDIR, SHARED_DATA ) ); };

    return $c->$cb( $@ || $!, $shared_data->{$id} );
};

get '/build/:sha' => { layout => 'result' } => sub {
    my $c   = shift;
    my $sha = $c->param('sha');

    # Retrieve of build data could be delayed if we are under heavy load.
    return $c->delay(
        sub { $c->build_data( $sha => shift->begin ) },
        sub {
            my ( $delay, $err, $build_data ) = @_;
            return $c->reply->not_found
                unless $build_data;
            return $c->param( build_data => $build_data )->render;
        },
    );
    },
    'build';

post '/event_handler' => sub {
    my $c          = shift;
    my $payload    = decode_json $c->param('payload');
    my $event_type = $c->req->headers->header('X-GitHub-Event');

    app->log->debug("Event type is $event_type");

    return $c->reply->not_found
        unless $event_type
        && $event_type eq "pull_request"
        && $payload
        && $payload->{action}
        && ( $payload->{action} eq "opened"
        || $payload->{action} eq "reopened" );

    app->log->debug("Job enqueued");
    app->minion->enqueue( build_repo => [ $payload, $event_type ] );

    return $c->render( text => "ENQUEUED" );
};

app->start;

__DATA__
@@ layouts/result.html.ep
<!DOCTYPE>
<html>
<head>
  <title><%= title %></title>
  <meta name="description" content="Sabayon build bot report">
  <meta name="viewport" content="width=device-width, initial-scale=0.9" />
  %= content 'head'
  %= asset 'app.js'
  %= asset 'app.css'
  %= stylesheet begin
  .alert {
      display: inline-block;
    margin: auto; display: table;
  }


  body, html {
      background-image: url(https://www.sabayon.org/img/intro-bg.jpg);
      background-attachment: fixed;
      background-size: cover;
  }

  .vertical-offset-100 {
      padding-top: 100px;
  }
% end
</head>


<body>
  %= content
</body>
</html>
@@ build.html.ep
<% if (param('build_data')->{status} and param('build_data')->{status} eq "building") { %>
%  content_for message => begin
   <meta http-equiv="refresh" content="3" >
% end
<% } else { %>
<script type="text/javascript">
$(function() {
      var ansi_up = new AnsiUp;

      var html = ansi_up.ansi_to_html(document.getElementById("build_output").innerHTML);

      var cdiv = document.getElementById("build_output");

      cdiv.innerHTML = html;
});
</script>
<% } %>
<div class="container vertical-offset-100">
    <div class="">
        <div class="text-center">
            <div class="panel-body">
                <div class="panel panel-default">
                    <table class="table table-hover table-bordered table-striped center-table text-center">
                        <thead>
                            <tr>
                                <th><i class="fa fa-bar-chart"></i> Status</th>
                              <% if (param('build_data')->{asset_url}){ %>
                                <th><i class="fa fa-download"></i> Artifacts</th>
                              <% } %>
                                <th><i class="fa fa-sign-out"></i> Exit status</th>
                            </tr>
                        </thead>
                        <tbody>
                            <tr>
                                <td>
                                <i class='fa fa-<%= param('build_data')->{status} eq "failure" ? "ban" : param('build_data')->{status} eq "building" ? "spinner" : "check" %>' aria-hidden="true"></i>
                                 <%= param('build_data')->{status} %>
                                 <i class="fa fa-clock-o"></i> <%= param('build_data')->{start_time} ? (time - param('build_data')->{start_time}) : "0" %> s
                                 </td>
                                <% if (param('build_data')->{asset_url}){ %>
                                <td>
                                  <a target="_blank" href="<%= param('build_data')->{asset_url} %>">Yes (Click to visit URL)</a>
                                </td>
                                <% } %>
                                <td><%= param('build_data')->{exit_status} ? param('build_data')->{exit_status} : "----" %></td>
                            </tr>
                            <tr class=""></tr>
                        </tbody>
                    </table>
                </div>
            </div>
        </div>
    </div>
    <div class="col-md-3 pull-md-left sidebar">
        <div class="panel panel-default">
            <div class="panel-heading"><i class="fa fa-car" aria-hidden="true"></i>  <strong class="">Useful Links</strong>
            </div>
            <div class="list-group">
<a href="https://www.sabayon.org/" class="list-group-item"><i class="fa fa-external-link" aria-hidden="true"></i> Sabayon Linux</a>
            </div>
        </div>
    </div>
    <div class="col-md-9">
        <% if (param('build_data')->{error}){ %>
        <div class="panel panel-default">
            <div class="panel-heading"><i class="fa fa-exclamation-circle"></i>  <strong class="">Errors</strong>

            </div>
            <div class="panel-body">
              <%= param('build_data')->{error} %>
            </div>
        </div>
        <% } %>
        <% if (param('build_data')->{output}){ %>
        <div class="panel panel-default">
            <div class="panel-heading"><i class="fa fa-info-circle"></i>  <strong class="">Information</strong>

            </div>
            <div class="panel-body" id="build_output">
            % foreach my $line (@{param('build_data')->{output}}) {
                <p><%= $line %></p>
                % }
            </div>
        </div>
        <% } %>
        <% if (param('build_data')->{message}){ %>
        <div class="panel panel-default">
            <div class="panel-heading"><i class="fa fa-info-circle"></i>  <strong class="">Message</strong>

            </div>
            <div class="panel-body">
              <%= param('build_data')->{message} %>
            </div>
        </div>
        <% } %>
    </div>
    <div class=""></div>
</div>

@@ not_found.html.ep
% layout 'result', title => "Page not found";
<div class="container vertical-offset-100">
  <div class="panel panel-default">
      <div class="panel-heading"><i class="fa fa-info-circle"></i>  <strong class="">Information</strong>

      </div>
      <div class="panel-body">
        Page not found!
      </div>
  </div>
</div>
@@ exception.production.html.ep
% layout 'result', title => "Server error";
<div class="container vertical-offset-100">
  <div class="panel panel-default">
      <div class="panel-heading"><i class="fa fa-info-circle"></i>  <strong class="">Exception</strong>

      </div>
      <div class="panel-body">
      <p><%= $exception->message %></p>
      <h1>Stash</h1>
      <pre><%= dumper $snapshot %></pre>
      </div>
  </div>
</div>
