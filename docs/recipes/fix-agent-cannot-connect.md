# Fix an agent that will not connect

An agent is running but never appears in TeamCity, or appears and takes no builds.

## It appears but takes no builds

It is connected but not authorized. This is TeamCity's default and the most common cause — the
agent is visibly present, so nothing looks wrong.

```sh
./tc authorize
```

See [agents](../tools/agents.md) for the access token this needs.

If it is authorized and still idle, check whether you are over the licence limit. Above three
authorized agents TeamCity pauses the **entire** build queue:

```sh
./tc doctor       # warns when authorized count exceeds the licence
```

## It never appears at all

Check what the agent thinks it is connecting to:

```sh
docker compose -f stack/docker-compose.yml --project-directory stack --env-file stack/.env \
  exec agent-1 printenv SERVER_URL
```

It must be `http://server:8111` — the service name on the stack network. `http://localhost:8111`
is the classic mistake: inside the agent container, `localhost` is the agent itself, so it retries
forever against nothing. The generated compose file always uses the service name; this only goes
wrong if the file has been hand-edited.

Then confirm the server is actually up:

```sh
./tc doctor
```

`up but awaiting first-run setup` means TeamCity is running but nobody has accepted the licence and
created the administrator account yet. Agents cannot register until that is done.

## It connected once and now does not

Its configuration volume holds the authorization token issued on first connection. If that volume
was deleted — by pruning, or by declining to keep it when scaling down — the agent registers as a
new one and needs authorizing again.

```sh
docker volume ls --filter name=teamcity_agent-1-conf
```

---

[← Docs index](../../README.md#documentation)
