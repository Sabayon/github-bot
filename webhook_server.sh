#!/bin/bash

echo "Building images and starting them"

[ ! -f webhook_env ] && echo "You need to have a webhook_env enviroment file" && exit 1

docker build -t sabayon/github-bot .

docker stop sabayon-github-bot-master sabayon-github-bot-worker1
docker rm sabayon-github-bot-master sabayon-github-bot-worker1

docker create \
              --entrypoint /bin/true \
              -v /app/shared \
              --name sabayon-github-bot-shared \
              sabayon/github-bot:latest

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
