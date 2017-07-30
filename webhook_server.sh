#!/bin/bash

echo "Building images and starting them"

[ ! -f webhook_env ] && echo "You need to have a webhook_env enviroment file" && exit 1

docker build -t sabayon/github-bot .

type ngrok >/dev/null 2>&1 && {
  pkill -9 ngrok
  nohup ngrok http 80 --log=info --log=stdout > ngrok.log &
  sleep 5

  export BASE_URL=$(curl -s http://127.0.0.1:4040/api/tunnels | \
                    grep -Po '"public_url":.*?[^\\]",' | \
                    perl -pe 's/"public_url"://; s/^"//; s/",$//' | \
                    xargs echo | awk '{ print $2 }') #we just want https version
}

docker stop sabayon-github-bot-master sabayon-github-bot-worker1
docker rm sabayon-github-bot-master sabayon-github-bot-worker1

docker create \
              --entrypoint /bin/true \
              -v /app/shared \
              --name sabayon-github-bot-shared \
              sabayon/github-bot:latest

[ -n "$BASE_URL" ] && docker run -tid \
                            --name sabayon-github-bot-master \
                            -p 80:3000 \
                            --volumes-from sabayon-github-bot-shared \
                            --env BASE_URL \
                            --env-file webhook_env \
                            --restart always \
                            sabayon/github-bot:latest \
                            prefork -m production || \
                      docker run -tid \
                            --name sabayon-github-bot-master \
                            -p 80:3000 \
                            --volumes-from sabayon-github-bot-shared \
                            --env-file webhook_env \
                            --restart always \
                            sabayon/github-bot:latest \
                            prefork -m production

docker run -tid -v /var/run/docker.sock:/var/run/docker.sock \
              --name sabayon-github-bot-worker1 \
              --volumes-from sabayon-github-bot-shared \
              --env-file webhook_env \
              --restart always \
              sabayon/github-bot:latest \
              minion worker

[ -n "$BASE_URL" ] &&  echo "Started ngrok tunnel to $BASE_URL" && \
                       echo "Your webhook url will be: $BASE_URL/event_handler"
