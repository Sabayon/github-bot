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
use Mojo::IOLoop::ReadWriteProcess qw(process);
use UUID::Tiny ':std';

use constant DEBUG => $ENV{DEBUG} // 0;
use constant GH_TOKEN        => $ENV{GH_TOKEN};
use constant CONTEXT         => $ENV{GH_CONTEXT} || "package build";
use constant BASE_URL        => $ENV{BASE_URL} || "127.0.0.1";
use constant WORKDIR         => $ENV{WORK_DIRECTORY} || cwd;
use constant MINION_DATA     => $ENV{MINION_DATA} || "minion.data";
use constant SHARED_DATA     => $ENV{SHARED_DATA} || "shared_data";
use constant BUILD_SCRIPT    => $ENV{BUILD_SCRIPT} || "./test_ci.sh";
use constant MESSAGE_FILE    => $ENV{MESSAGE_FILE} || "MESSAGE";
use constant FA_URL          => $ENV{FA_URL};
use constant AUTH_TOKEN      => $ENV{AUTH_TOKEN} || 'MyBygSecret';
use constant HOST_SHARED_DIR => $ENV{HOST_SHARED_DIR} || '/tmp/container';
use constant KEY_DIR         => $ENV{KEY_DIR} || WORKDIR . "/keys";
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
        'https://cdnjs.cloudflare.com/ajax/libs/jquery.terminal/1.8.0/css/jquery.terminal.min.css'
    )
);
app->asset->process(
    'app.js' => (
        'https://code.jquery.com/jquery-3.1.0.min.js',
        'https://maxcdn.bootstrapcdn.com/bootstrap/3.3.7/js/bootstrap.min.js',
        'https://raw.githubusercontent.com/drudru/ansi_up/master/ansi_up.js',
        'https://cdnjs.cloudflare.com/ajax/libs/jquery.terminal/1.8.0/js/jquery.terminal.min.js',
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
        my $msg_file = path( $build_dir, ARTIFACTS_FOLDER, MESSAGE_FILE );
        if ( -e $msg_file ) {
            $shared_data{$sha}{message} = $msg_file->slurp;
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

# Main task that execute our custom BUILD_SCRIPT
app->minion->add_task(
    single_build => sub {

        my ( $job, $parameters ) = @_;

        my $current_dir = cwd;

        my $repo      = $parameters->{repo};
        my $dir       = $parameters->{folder};
        my $namespace = $parameters->{namespace};
        my $id        = $parameters->{id};

        my $status_url = BASE_URL . "/job/$id";

        $job->app->log->info("ID $id repo $repo dir $dir - Build received");

        my %shared_data;

        $shared_data{"ci"}{$id}{status}     = "building";
        $shared_data{"ci"}{$id}{start_time} = time;

        lock_store \%shared_data, path( WORKDIR, SHARED_DATA );

        # Execute the build.
        # Passing the github data into the process STDIN
        my $return;
        my $workdir = tempdir( DIR => HOST_SHARED_DIR );

        $job->app->log->debug("Working on $workdir");

        chdir($workdir);
        git::clone $repo, "repo";
        my $build_dir = path( $workdir, "repo", $dir );

        chdir($build_dir) if -d $build_dir;
        local $ENV{ARTIFACTS_FOLDER} = ARTIFACTS_FOLDER;

      #local $ENV{GENKEY_PHASE}     = "true";  # key autogen is broken for now
        system( "cp -rf " . KEY_DIR . " $build_dir/confs" ) if -d KEY_DIR;
        $job->app->log->debug( "Exposed environment " . `env` );

        my $p = process(
            execute      => '/usr/bin/sark-buildrepo',
            separate_err => 0
        )->start();

        $shared_data{"ci"}{$id}{pid} = $p->pid;
        lock_store \%shared_data, path( WORKDIR, SHARED_DATA );
        $shared_data{"ci"}{$id}{output} = [];

        my $stdout = $p->read_stream;
        while ( defined( my $line = <$stdout> ) ) {
            $job->app->log->debug($line);
            push( @{ $shared_data{"ci"}{$id}{output} }, $line );
            lock_store \%shared_data,
                path( WORKDIR, SHARED_DATA );    # potentially distructive
        }

        push( @{ $shared_data{"ci"}{$id}{output} }, $p->getlines );

        $job->app->log->debug("End output");
        $p->wait_stop;
        $return = $p->exit_status;
        $shared_data{"ci"}{$id}{error} = $p->error->join("\n")
            and $return = 1
            if $p->errored;                      # Collect (might-be) errors

        chdir($current_dir);
        $job->app->log->debug("Checking for artifacts in $current_dir");

        my $asset = path( $build_dir, ARTIFACTS_FOLDER );
        if ( -d $asset ) {
            $job->app->log->debug("Found asset: $asset");
            my $dest =
                path( ROOTDIR_STATIC_FILES, "repo", $namespace )->make_path;
            $job->app->log->debug("Copying $asset to $dest");
            system("cp -rfv $asset $dest");

            $shared_data{"ci"}{$id}{asset} = $dest->to_string;
            $shared_data{"ci"}{$id}{asset_url} =
                BASE_URL . "/repo/$namespace";
        }

        $job->app->log->debug("Cleanup $workdir");
        path($workdir)->remove_tree;

        my $state = $return != 0 ? "failure" : "success";

        $shared_data{"ci"}{$id}{return}      = $return;
        $shared_data{"ci"}{$id}{exit_status} = $return >> 8;
        $shared_data{"ci"}{$id}{status}      = $state;
        $job->app->log->debug( "Saved build status for '$id' : "
                . Dumper( $shared_data{"ci"}{$id} ) );

        lock_store \%shared_data, path( WORKDIR, SHARED_DATA );

        $job->app->log->debug("ID: $id $state - Build finished");
    }
);

helper build_data => sub {
    my $cb = pop;
    my ( $c, $id ) = @_;
    my $shared_data;
    local ( $!, $@ );
    eval { $shared_data = lock_retrieve( path( WORKDIR, SHARED_DATA ) ); };
    $shared_data->{$id}->{sha} = $id;
    return $c->$cb( $@ || $!, $shared_data->{$id} );
};

helper job_data => sub {
    my $cb = pop;
    my ( $c, $id ) = @_;
    my $shared_data;
    local ( $!, $@ );
    eval { $shared_data = lock_retrieve( path( WORKDIR, SHARED_DATA ) ); };
    $shared_data->{ci}->{$id}->{id} = $id;
    return $c->$cb( $@ || $!, $shared_data->{ci}->{$id} );
};

helper list_jobs => sub {
    my $cb = pop;
    my ($c) = @_;
    my $shared_data;
    local ( $!, $@ );
    eval { $shared_data = lock_retrieve( path( WORKDIR, SHARED_DATA ) ); };
    return $c->$cb( $@ || $!, $shared_data->{ci} );
};

helper stop_job => sub {
    my $cb = pop;
    my ( $c, $id ) = @_;
    my $shared_data;
    local ( $!, $@ );
    eval { $shared_data = lock_retrieve( path( WORKDIR, SHARED_DATA ) ); };
    return $c->$cb( $@ || $!, 0 )
        unless exists $shared_data->{ci}->{$id}->{pid};

    my $process = process( blocking_stop => 1 )
        ->pid( $shared_data->{ci}->{$id}->{pid} );
    $process->stop();

    return $c->$cb( $@ || $!, $process->is_running );
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

get '/build/:sha/stream_output' => { layout => 'result' } => sub {
    my $c   = shift;
    my $sha = $c->param('sha');
    my $pos = $c->param('pos');

    # Retrieve of build data could be delayed if we are under heavy load.
    return $c->delay(
        sub { $c->build_data( $sha => shift->begin ) },
        sub {
            my $build_data = pop;
            my ( $delay, $err ) = @_;
            return $c->reply->not_found
                unless $build_data;
            return $c->param(
                build_data => substr( "@{$build_data->{output}}", $pos ) )
                ->render;
        },
    );
    },
    'build';

get '/job/:id' => { layout => 'result' } => sub {
    my $c  = shift;
    my $id = $c->param('id');

    # Retrieve of build data could be delayed if we are under heavy load.
    return $c->delay(
        sub { $c->job_data( $id => shift->begin ) },
        sub {
            my $build_data = pop;
            my ( $delay, $err ) = @_;
            return $c->reply->not_found
                unless $build_data;
            return $c->param( build_data => $build_data )->render;
        },
    );
    },
    'build';

get '/job/:id/output' => { layout => 'result' } => sub {
    my $c  = shift;
    my $id = $c->param('id');

    # Retrieve of build data could be delayed if we are under heavy load.
    return $c->delay(
        sub { $c->job_data( $id => shift->begin ) },
        sub {
            my $build_data = pop;
            my ( $delay, $err ) = @_;
            return $c->reply->not_found
                unless $build_data;
            return $c->render(
                text => join( "\n", @{ $build_data->{output} } ) );
        },
    );
    },
    'build';

get '/job/:id/stream_output' => { layout => 'result' } => sub {
    my $c   = shift;
    my $id  = $c->param('id');
    my $pos = $c->param('pos');

    # Retrieve of build data could be delayed if we are under heavy load.
    return $c->delay(
        sub { $c->job_data( $id => shift->begin ) },
        sub {
            my $build_data = pop;
            my ( $delay, $err ) = @_;
            return $c->reply->not_found
                unless $build_data;
            return $c->render(
                text => substr( "@{$build_data->{output}}", $pos ) );
        },
    );
    },
    'build';

group {

    # Global logic shared by all routes
    under sub {
        my $c = shift;
        return 1
            if $c->param('AUTH_TOKEN')
            && $c->param('AUTH_TOKEN') eq AUTH_TOKEN;
        $c->render( text => "Invalid token" );
        return undef;
    };

    get '/jobs' => { layout => 'result' } => sub {
        my $c = shift;

        # Retrieve of build data could be delayed if we are under heavy load.
        return $c->delay(
            sub { $c->list_jobs( shift->begin ) },
            sub {
                my ( $delay, $err, $jobs ) = @_;
                return $c->reply->not_found
                    unless $jobs;
                return $c->param( jobs => $jobs )->render;
            },
        );
        },
        'list_build';

    post '/build' => sub {
        my $c          = shift;
        my $parameters = $c->req->json;

        return $c->render( text => "Invalid parameters" )
            unless $parameters
            && $parameters->{repo}
            && $parameters->{namespace}
            && $parameters->{folder};

        app->log->debug("Job enqueued");
        $parameters->{id} = create_uuid_as_string(UUID_RANDOM);
        app->minion->enqueue( single_build => [$parameters] );

        return $c->render( text => BASE_URL . "/job/" . $parameters->{id} );
    };

    get '/job/:id/stop' => sub {
        my $c  = shift;
        my $id = $c->param('id');

        return $c->delay(
            sub { $c->stop_job( $id => shift->begin ) },
            sub {
                my ( $delay, $err, $done ) = @_;
                return $c->render( text => "Still running" )
                    if $done;
                return $c->render( text => "Stopped" );
            },
        );
    };

};

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
  %= asset 'app.css'
  %= asset 'app.js'
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
<style>
@keyframes blink {
    50% {
        color: #000;
        background: #0c0;
        -webkit-box-shadow: 0 0 5px rgba(0,100,0,50);
        box-shadow: 0 0 5px rgba(0,100,0,50);
    }
}
@-webkit-keyframes blink {
    50% {
        color: #000;
        background: #0c0;
        -webkit-box-shadow: 0 0 5px rgba(0,100,0,50);
        box-shadow: 0 0 5px rgba(0,100,0,50);
    }
}
@-ms-keyframes blink {
    50% {
        color: #000;
        background: #0c0;
        -webkit-box-shadow: 0 0 5px rgba(0,100,0,50);
        box-shadow: 0 0 5px rgba(0,100,0,50);
    }
}
@-moz-keyframes blink {
    50% {
        color: #000;
        background: #0c0;
        -webkit-box-shadow: 0 0 5px rgba(0,100,0,50);
        box-shadow: 0 0 5px rgba(0,100,0,50);
    }
}
.terminal {
    --background: #000;
    --color: #0c0;
    text-shadow: 0 0 3px rgba(0,100,0,50);
}
.cmd .cursor.blink {
    -webkit-animation: 1s blink infinite;
    animation: 1s blink infinite;
    -webkit-box-shadow: 0 0 0 rgba(0,100,0,50);
    box-shadow: 0 0 0 rgba(0,100,0,50);
    border: none;
    margin: 0;
}
</style>

<script type='text/javascript'>

	  $(document).ready(function() {
      var pos = 0;
      var build_data;

      var save_state = [];
      var term = $('#terminal').terminal(function(command, term) {},{
          greetings: 'Build',
          name: 'build',
          height: 500,
      });

      save_state.push(term.export_view()); // save initial state
      $(window).on('popstate', function(e) {
          if (save_state.length) {
              term.import_view(save_state[history.state || 0]);
          }
      });

      getData();

      <% if (param('build_data')->{status} and param('build_data')->{status} eq "building") { %>
          setInterval(getData, 6000);
      <% } %>

      function getData() {
        $.ajax({
        <% if (param('build_data')->{id}) { %>
        url: "/job/<%= param('build_data')->{id} %>/stream_output",
        <% } elsif (param('build_data')->{sha}) { %>
            url: "/build/<%= param('build_data')->{sha} %>/stream_output",
        <% } %>
            data: {
                 "pos": pos,
             },
            beforeSend: function( xhr ) {
              xhr.overrideMimeType( "text/plain; charset=x-user-defined" );
            }
          })
          .done(function( data ) {
           build_data += data;
           pos = build_data.length;
              term.echo(data).resume();
          });
        }
		});

</script>

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

            <div class="panel-heading"><i class="fa fa-info-circle"></i>  <strong class="">Information</strong></div>
            <div class="panel-body" id="terminal">Loading terminal...</div>
            <div class="panel-body" id="build_output">
            % foreach my $line (@{param('build_data')->{output}}) {
            % #    <p><%= $line %></p>
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
@@ list_build.html.ep
%  content_for message => begin
   <meta http-equiv="refresh" content="3" >
% end
<div class="container vertical-offset-100">
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
        <div class="panel panel-default">
            <div class="panel-heading"><i class="fa fa-info-circle"></i>  <strong class="">Jobs</strong>
            </div>
            <div class="panel-body" id="build_output">
            % foreach my $line (keys %{ param('jobs') }) {
                <p><a href="/job/<%= $line %>" target="_blank"><%= $line %></a></p>
                % }
            </div>
        </div>

    </div>
    <div class=""></div>
</div>
