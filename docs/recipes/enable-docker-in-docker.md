# Enable Docker builds on agents

Let build agents run `docker` commands.

Two options, both set through **Reconfigure** or `TC_AGENT_DOCKER` in `stack/.env`.

## Docker-in-Docker

```sh
$EDITOR stack/.env     # TC_AGENT_DOCKER='dind'
./tc restart
```

Each agent runs its own isolated Docker daemon. This requires `privileged: true`, which can be
escaped from into the Docker VM — so use it only with builds you are willing to trust at that
level.

It forces the full agent image (the minimal one has no Docker) and gives each agent its own
`/var/lib/docker` volume, so image layers survive restarts instead of being re-pulled on every
build.

## Host socket

```sh
$EDITOR stack/.env     # TC_AGENT_DOCKER='socket'
./tc restart
```

Mounts the host daemon's socket into each agent. Much lighter than Docker-in-Docker — no nested
daemon, no privileged container, shared image cache — but any build can then control the host
daemon, which is root-equivalent on the VM. A build can start a container that mounts anything.

## Which

Docker-in-Docker for isolation at the cost of a privileged container and disk. The host socket for
speed and simplicity, when every build running on these agents is trusted. `none` — the default —
if agents do not need Docker at all.

---

[← Docs index](../../README.md#documentation)
