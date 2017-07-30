# [![Docker Build Statu](https://img.shields.io/docker/build/sabayon/github-bot.svg?style=flat-square)](sabayon/github-bot) Sabayon Build Bot


# Deploy

Create a file that contains the environment of the application, and start the containers with the environment file:

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

Note: replace `webhook_env` in the command with your file name.
