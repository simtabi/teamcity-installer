# Architecture

How the console, the stack and your machine fit together, and the reasoning behind the choices
that are not obvious.

## The shape of it

```
your machine                    Docker daemon
──────────────                  ─────────────────────────────────────
  ./tc  ──────────────────────▶  console container
   │    (only host-side file)     (menu, gum, docker CLI, compose)
   │                                    │
   │                                    │ drives, via the bind-mounted socket
   │                                    ▼
   │                              ┌─────────────────────────────┐
   │                              │  db        postgres:17      │
   └── stack/, backups/ ────────▶ │  server    teamcity-server  │
       (config and archives       │  agent-1..N teamcity-agent  │
        only; no runtime state)   └─────────────────────────────┘
                                          │
                                    named volumes
                                  (all TeamCity state)
```

Three layers, each with one job. `./tc` resolves the daemon socket and launches the console. The
console renders a compose file and runs Docker commands. The stack is ordinary Compose services.

## Why the console is containerized

The brief was that nothing may be installed on the machine. A control script that needs `gum` for
its interface, `jq` for REST responses, `flock` for locking and `shellcheck` for its own linting
would normally mean a `brew install` list. Putting the script in an image moves that entire
dependency set inside Docker, where it is already accepted that things get installed.

What remains on the host is `./tc`: a POSIX shell script that calls nothing but `docker`.

The cost is that the console cannot see your machine directly — it cannot open a browser, and it
reads the host filesystem only through the mounts it is given. Both show up in the design: the
`Open` action prints a URL rather than launching anything, and the project directory is mounted
explicitly.

## Why the project is mounted at its own absolute path

The console runs with `-v "$ROOT":"$ROOT" -w "$ROOT"`, so the project has the same absolute path
inside the container as outside.

This matters because of who resolves bind mounts. When the console runs
`docker run -v /Users/you/teamcity/backups:/out …`, that path is interpreted by the **daemon**, on
the host — not inside the console container. Mount the project at `/workspace` instead, and the
console would ask the daemon for a `/workspace` that does not exist there, and backups would land
somewhere invisible. Identical paths remove the translation problem rather than solving it.

## Why the socket is resolved, not hardcoded

Almost every "dockerized tool" recipe mounts `/var/run/docker.sock`. On this machine that file
does not exist: OrbStack puts the socket at `~/.orbstack/run/docker.sock`. The launcher therefore
asks Docker itself:

```sh
docker context inspect --format '{{.Endpoints.docker.Host}}'
```

and falls back to `$DOCKER_HOST` and then the classic path. It also refuses a `tcp://` or `ssh://`
context with an explanation, since neither can be bind-mounted.

## Why named volumes, not bind mounts

Every piece of TeamCity state — data directory, database, agent configuration, caches, logs —
lives in a named Docker volume. Nothing runtime is written to the host filesystem.

Two reasons. It is what "installs nothing on your machine" means in practice: uninstalling is
`./tc reset` plus deleting the directory. And on macOS, bind mounts cross a virtualisation
boundary, which is measurably slow for the write-heavy work TeamCity does. Named volumes live
inside the Docker VM.

The exceptions are deliberate: `stack/` holds configuration you may want to read or version, and
`backups/` holds archives that are useless if you cannot get at them.

## Why the compose file is generated

`stack/docker-compose.yml` is rendered from `stack/.env` on every lifecycle command rather than
maintained by hand. Changing the agent count from 3 to 5, or turning on Docker-in-Docker, would
otherwise mean a careful multi-place edit. As a generated artifact it is a re-render.

It also gives somewhere to enforce invariants. `render::validate_config` re-runs every validator
before writing, so a hand-edited `.env` is rejected with a specific reason instead of producing a
stack that fails obscurely later.

Agents are rendered as explicit `agent-1`, `agent-2` … services rather than using `deploy.replicas`
because each agent needs **its own** configuration volume. That volume holds the authorization
token the server issues on first connection; sharing one across replicas means agents fight over
an identity, and losing it means re-authorizing on every restart.

## Why every declared volume is mapped

The TeamCity images declare more volumes than are obvious: the server declares three
(`datadir`, `logs`, `temp`) and the full agent declares eight (`conf`, `work`, `system`, `temp`,
`logs`, `tools`, `plugins`, and `/var/lib/docker`).

Docker creates an **anonymous volume** for any declared `VOLUME` left unmapped. Nothing fails, and
two things quietly go wrong: the agent's tool and plugin caches are discarded on every recreate,
so builds re-download them; and dead volumes accumulate on the daemon with no name to identify
them by. The renderer maps all eleven, and `./tc doctor` reports the anonymous-volume count as a
regression check.

## Why the data directory is seeded as root

`datadir-init` runs before the server, writes the PostgreSQL JDBC driver and `database.properties`
into the data directory, then `chown -R 1000:1000` on the way out.

The ordering is forced. The server image runs as `tcuser` (uid 1000), and it `chown`s the data
directory path at **build** time — which does not apply to a named volume seeded by a different
container. A fresh volume mounted into an Alpine container that has nothing at that path comes up
owned by `root:root`, so a uid-1000 init container could not create a directory in it, let alone
write to it. Seeding as root and handing over ownership last is the only order that works.

The payoff is that TeamCity's first-run web wizard finds a configured database and skips that step
entirely.

## Why `.env` is parsed rather than sourced

`conf::load` reads `stack/.env` line by line instead of `source`-ing it.

`source` looked simpler until `TC_MEM_OPTS=-Xmx2g -XX:ReservedCodeCacheSize=640m`. Compose reads
that as one value; bash reads it as an assignment followed by a command, and tries to execute
`-XX:ReservedCodeCacheSize=640m`. One file cannot mean two things. Values are now written
single-quoted — which Compose strips and the parser understands — and the parser only assigns to
names matching `^[A-Za-z_][A-Za-z0-9_]*$`.

It also closes a smaller hole: this file is documented as hand-editable and holds a password, and
a config file should not be able to execute.

## Where secrets live

| File | Contents | Mode |
|---|---|---|
| `stack/.env` | everything Compose interpolates, including the database password | 600 |
| `stack/.secrets` | the TeamCity REST access token | 600 |

They are separate on purpose. Everything in `.env` appears in `docker compose config` output and
in any diagnostics bundle built from it. The access token is never referenced by the compose file,
so keeping it out of `.env` keeps it out of both. Both files are gitignored.

## Failure behaviour

The interactive menu installs an `ERR` trap that reports the failing file, line and command, then
returns to the menu — an unexpected error should not eject you from the container.

One-shot commands deliberately do **not** arm that trap. `./tc status` returning non-zero means
"the stack is not fully running", which is a result, not a fault; bash cannot tell the two apart
from a trap, so the distinction is drawn by mode. Commands print their own errors and propagate
their exit code.

## Why bash, and how it is kept honest

The console is ~2,400 lines of bash. That is past the size where bash is obviously the right
choice, and the language did cost us: the bugs found during development were bash-specific — an
unquoted regex operand splitting on a space, `source` executing a config file, a trailing `&&`
making a function return non-zero under `set -e`.

Go was considered. It was rejected because its headline advantage — a static binary with no
runtime dependencies — is already delivered by shipping as a container image, and because roughly
70% of the code is invoking `docker` and formatting its output, which is bash's home turf. An ops
tool people fork and tweak is also cheaper to edit in bash than behind a toolchain.

What Go would genuinely have bought is type safety over the pure logic, and that is bought more
cheaply with tests. `./tc test` runs 47 bats cases over exactly those parts — validators, the
renderer, `.env` round-tripping, restore compatibility, version ordering — with `docker` and the
network stubbed so the suite needs no daemon.

Revisit the decision if this grows a long-running daemon, real concurrency, or a state machine.
None are on the horizon. The full reasoning, the triggers that would justify a rewrite, and what
a Go v2 would look like are recorded in [roadmap](roadmap.md).

---

[← Docs index](../README.md#documentation)
