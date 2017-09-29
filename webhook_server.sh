#!/bin/bash

export ENVFILE="${ENVFILE:-webhook_env}"
export EXT_PORT="${EXT_PORT:-8080}"

[ ! -f $ENVFILE ] && echo "You need to have a $ENVFILE enviroment file" && exit 1

echo "Building images and starting them"

[ -n "$BUILD_IMAGE" ] && docker build -t sabayon/github-bot .


docker network create sabayon-github-bot

docker stop sabayon-github-bot-master sabayon-github-bot-worker1
docker rm sabayon-github-bot-master sabayon-github-bot-worker1

docker create \
              --entrypoint /bin/true \
              -v /app/shared \
              --name sabayon-github-bot-shared \
              sabayon/github-bot:latest

docker run -tid \
              --name sabayon-github-bot-master \
              --network sabayon-github-bot \
              -p $EXT_PORT:3000 \
              --volumes-from sabayon-github-bot-shared \
              --env-file $ENVFILE \
              --restart always \
              sabayon/github-bot:latest \
              prefork -m production

docker run -tid -v /var/run/docker.sock:/var/run/docker.sock \
              --name sabayon-github-bot-worker1 \
              --network sabayon-github-bot \
              --volumes-from sabayon-github-bot-shared \
              -v /tmp/container:/tmp/container/ \
              --env-file $ENVFILE \
              --restart always \
              sabayon/github-bot:latest \
              minion worker

[ -n "$NGROK" ] && {
  docker run -d -p 4040 \
                    -e NGROK_PORT=sabayon-github-bot-master:3000 \
                    --network sabayon-github-bot \
                    --name sabayon-github-bot-ngrok wernight/ngrok

  sleep 5

  export BASE_URL=$(curl -s $(docker port sabayon-github-bot-ngrok 4040)/api/tunnels | \
                    grep -Po '"public_url":.*?[^\\]",' | \
                    perl -pe 's/"public_url"://; s/^"//; s/",$//' | \
                    xargs echo | awk '{ print $2 }') #we just want https version
}

[ -n "$BASE_URL" ] && \
          docker stop sabayon-github-bot-master && \
          docker rm sabayon-github-bot-master && \
          docker run -tid --name sabayon-github-bot-master \
                            -p $EXT_PORT:3000 --network sabayon-github-bot \
                            --volumes-from sabayon-github-bot-shared \
                            --env BASE_URL \
                            --env-file $ENVFILE \
                            --restart always \
                            sabayon/github-bot:latest \
                            prefork -m production && \
        echo "Started service to $BASE_URL" && \
        echo "Your webhook url will be: $BASE_URL/event_handler"
