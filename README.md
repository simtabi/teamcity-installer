# simtabi/teamcity-installer

<!-- No badges: this is an internal tool with no package registry and no CI pipeline,
     so the standard registry / tests / static-analysis / licence row does not apply. -->

> A containerized control console that installs, runs, backs up and upgrades a local JetBrains TeamCity stack without installing anything on your machine.

Requires Docker (OrbStack or Docker Desktop) with the Compose v2 plugin. Runs on macOS (Apple Silicon and Intel), Linux, and Windows via WSL 2.

## Install

```sh
git clone https://github.com/simtabi/teamcity-installer.git
cd teamcity-installer
make            # list what is available
make install    # guided setup
```

Or drive it directly — `make` is a convenience, not a dependency:

```sh
./tc            # interactive menu
```

That is the whole installation. `./tc` is a POSIX shell script whose only dependency is the
`docker` binary you already have; it builds a console image on first run and drops you into a
guided setup. No JRE, no Tomcat, no system services, and nothing written outside this directory —
TeamCity's data lives in named Docker volumes.

The first run asks a handful of questions, then brings up a TeamCity server, a PostgreSQL database
and three build agents, with the database already configured so TeamCity's own setup wizard skips
straight to the licence agreement — and it hands you the super user token that page asks for,
which otherwise lives in a log file inside a Docker volume.

## <a name="documentation"></a>Documentation

### Guides

- [Installation](docs/installation.md) — requirements, what the first run does, how to remove it
- [Getting started](docs/getting-started.md) — from `./tc` to a green build agent
- [Users](docs/users.md) — the super user token, the first administrator, and adding more
- [Data safety](docs/data-safety.md) — what destroys data (only one command) and what does not
- [Configuration](docs/configuration.md) — every setting in `stack/.env` and what changes it
- [Architecture](docs/architecture.md) — how the pieces fit, and why the console is containerized
- [Changelog](CHANGELOG.md) — what changed, and when
- [Roadmap](docs/roadmap.md) — what v2 would be, and the triggers that would justify it
- [Platforms](docs/platforms.md) — macOS, Linux and WSL, and the limits of what has been tested
- [Publishing](docs/publishing.md) — the open-source position, and what is left before a first push
- [Release](docs/release.md) — the pinned TeamCity version and how to move it

### Reference

- [Console](docs/tools/console.md) — the launcher, the menu, and non-interactive commands
- [Wizard](docs/tools/wizard.md) — guided setup and what each answer controls
- [Stack](docs/tools/stack.md) — the generated compose file, services and volumes
- [Agents](docs/tools/agents.md) — scaling, authorizing and pruning build agents
- [Backup](docs/tools/backup.md) — the three backup tiers and restore compatibility rules
- [Upgrade](docs/tools/upgrade.md) — version changes, guards and the maintenance token
- [Doctor](docs/tools/doctor.md) — diagnostics and the exported bundle
- [Verify](docs/tools/verify.md) — live end-to-end checks, and how they pair with the bats suite
- [Logging](docs/tools/logging.md) — one log per tool, redaction, rotation and `./tc journal`

### Recipes

- [Change the port](docs/recipes/change-port.md)
- [Add an agent](docs/recipes/add-agent.md)
- [Switch to PostgreSQL](docs/recipes/switch-to-postgres.md)
- [Restore from a backup](docs/recipes/restore-from-backup.md)
- [Enable Docker builds on agents](docs/recipes/enable-docker-in-docker.md)
- [Fix an agent that will not connect](docs/recipes/fix-agent-cannot-connect.md)
- [Fix a rejected super user token](docs/recipes/token-rejected.md)

## Contributing & security

`make check` — lint, 89 unit tests and the live checks — must pass. Everything runs inside the
console image, so none of it needs anything installed. Report security issues privately to the
maintainers rather than opening a public issue.

## License

[MIT](LICENSE) © 2026 Simtabi. Author: Imani Manyara.

TeamCity is a trademark of JetBrains s.r.o. This project is not affiliated with or endorsed by
JetBrains and redistributes no JetBrains software — see [NOTICE](NOTICE).
