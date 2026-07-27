# Installation

What you need, what the first run does, and how to remove everything again.

## Requirements

| Requirement | Notes |
|---|---|
| Docker | OrbStack or Docker Desktop. The daemon must be running. |
| Compose v2 | Bundled with both. The console carries its own copy as well. |
| Memory | 4 GiB allocated to Docker minimum, 6 GiB or more comfortable |
| Disk | ~10 GiB for images, plus whatever your builds produce |
| Architecture | arm64 and amd64 are both published; arm64 runs natively on Apple Silicon |

Nothing else. No Java, no Tomcat, no PostgreSQL client. `./tc` uses only the `docker` binary.

## Installing

```sh
cd teamcity
./tc
```

The first run:

1. Resolves the Docker socket from your active context and checks the daemon is reachable.
2. Builds the console image — around 200 MB, once, and again only when `console/` changes.
3. Drops you into the menu, where **Install** starts the guided setup.

See [wizard](tools/wizard.md) for what each question controls. Accepting every default gives you
TeamCity 2026.1.3 on port 8111, PostgreSQL 17, and three build agents.

Bringing the stack up pulls roughly 8 GiB of images the first time; subsequent starts are seconds.

## Verifying

```sh
./tc status
./tc doctor
```

`status` exits non-zero when the stack is not fully running, so it is safe to use in a script.
`doctor` runs the full probe set: container health, HTTP readiness, database connectivity, agent
registration, volume usage.

## What gets written where

| Location | Contents | Survives reset |
|---|---|---|
| Named Docker volumes | all TeamCity data, the database, agent state | no |
| `stack/.env` | your settings, and the database password | no |
| `stack/.secrets` | the REST access token | no |
| `stack/docker-compose.yml` | generated, rebuilt on every command | no |
| `backups/` | archives and diagnostics bundles | yes |

Nothing is written outside this directory. No launchd or systemd units, no `~/.BuildServer`, no
entries in `/usr/local`.

## Removing it

```sh
./tc reset     # destroys the stack and every volume it owns
```

`reset` requires you to type the stack name; it does not accept a plain yes. It leaves `backups/`
alone.

To remove the tooling as well:

```sh
docker rmi $(docker images -q teamcity-console)
cd .. && rm -rf teamcity
```

Then `docker image prune` if you also want the TeamCity and PostgreSQL images gone. At that point
nothing from this project remains on the machine.

---

[← Docs index](../README.md#documentation)
