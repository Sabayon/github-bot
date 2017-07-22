FROM sabayon/base-amd64

MAINTAINER mudler <mudler@sabayonlinux.org>

# Set locales to en_US.UTF-8
ENV LC_ALL=en_US.UTF-8
ENV ACCEPT_LICENSE=*

RUN equo up && equo u && equo i dev-perl/App-cpanminus \
				dev-perl/Net-SSLeay \
				dev-perl/libwww-perl \
				dev-perl/Moo \
				dev-perl/Sereal-Decoder \
				dev-perl/Sereal-Encoder \
				app-emulation/docker

RUN cpanm Mojolicious \
                   Net::GitHub \
                   Mojolicious::Plugin::Minion \
                   Minion::Backend::Storable \
                   Minion \
                   Mojolicious::Plugin::AssetPack \
                   IPC::Open3 \
                   Storable \
                   Git::Sub \
                   Mojo::File && mkdir /app

ADD event_handler.pl /app/app.pl

# Set environment variables.
ENV HOME /app

# Define working directory.
WORKDIR /app

# Define default command.
ENTRYPOINT ["/usr/local/bin/hypnotoad", "/app/app.pl"]
