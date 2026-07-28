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

Verified on macOS/arm64: the agent's daemon reports a different daemon ID to the host's, so the
isolation is real rather than nominal, and containers it starts are invisible to `docker ps` on
your machine.

## Host socket

```sh
$EDITOR stack/.env     # TC_AGENT_DOCKER='socket'
./tc restart
```

Mounts the host daemon's socket into each agent. Much lighter than Docker-in-Docker — no nested
daemon, no privileged container, shared image cache — but any build can then control the host
daemon, which is root-equivalent on the VM. A build can start a container that mounts anything.

The mount alone is not enough, and this is the trap. The agent runs as uid 1000 with a `docker`
group of its own — GID 999 in JetBrains' image — while the socket belongs to whatever group the
*host* uses: root on OrbStack and Docker Desktop, a real docker group on most Linux installs. When
those disagree, every `docker` command in a build fails with

```
permission denied while trying to connect to the Docker API at unix:///var/run/docker.sock
```

and nothing about the configuration looks wrong — the bind mount is plainly there.

So the compose file grants the agent the socket's *actual* group, read at render time from the
socket the console already has mounted:

```yaml
    group_add:
      - "0"          # whatever `stat -c %g /var/run/docker.sock` reports here
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
```

A supplementary group, not `user: root` — the agent keeps its own uid and gains nothing beyond the
socket. Re-render (`./tc restart`) after moving the project between machines, since the right GID
differs between them.

## Which

Docker-in-Docker for isolation at the cost of a privileged container and disk. The host socket for
speed and simplicity, when every build running on these agents is trusted. `none` — the default —
if agents do not need Docker at all.

Both modes were exercised end to end on macOS/arm64 — daemon reachable, a container actually run,
and for `dind` the daemon ID compared against the host's to confirm separation.

---

[← Docs index](../../README.md#documentation)
