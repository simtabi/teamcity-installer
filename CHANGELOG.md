# Changelog

Notable changes to this project. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versioning follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] — 2026-07-28

Everything below was found by running the tool against a live server, not by reading the code.

### Added

- **`./tc admin`** — creates the first administrator over REST and grants it `SYSTEM_ADMIN`,
  automatically when the server comes up with no accounts. A started TeamCity with zero users
  answers 200 and looks healthy while being impossible to sign in to.
- **Unattended agent authorization** during `up`, so a fresh install needs no follow-up command.
- **A missing `stack/.env` is created** from the tracked example with a generated password. A fresh
  clone previously failed every command with "No stack configured".
- **Configuration is validated before any command acts on it**, naming the offending setting rather
  than failing somewhere less obvious later.
- **`./tc shell`, `./tc open`, `./tc reconfigure`, `./tc prune`** — previously menu-only or
  missing, so nothing using them could be scripted. Every command now has a `make` target, and
  tests hold the menu, CLI and `make` surfaces in step.
- **Logging** — one file per tool under `logs/`, with session ids, secret redaction and rotation.

### Fixed

- **The interactive menu was broken.** `ui::spin` passed shell functions to `gum spin`, which execs
  a binary; 16 call sites failed under a terminal. Every test had run without one, so the suite
  exercised the branch that worked. A pseudo-terminal harness now covers the branch users hit.
- **Every native backup failed**, reported as a permissions error. It was content negotiation:
  `/app/rest/server/backup` returns 406 to an `Accept: application/json` request.
- **CI had failed on every push** while `make check` passed locally — git refused to operate on the
  bind-mounted checkout as root.
- **Three prompts blocked forever** on an exhausted stdin, hanging any piped or CI run.
- Restores could not put credentials back, because the only configuration in an archive was
  redacted — while the same password sat in plaintext elsewhere in the same archive.
- `./tc token` now verifies the token against the server; it rotates on every restart, and a stale
  one is rejected with a message that does not mention staleness.
- The backup check runs by default: the native tier never paused the server, contrary to its own
  skip message.

### Removed

- **Agent auto-authorization.** Implemented against TeamCity's documented
  `teamcity.agentAutoAuthorize.authorizationToken` and removed after verification: the server reads
  the property and matching agents still register as Unauthorized. Authorization is explicit.

## [0.1.0] — 2026-07-27

First public release. Pins TeamCity **2026.1.3** against the official JetBrains images.

### Added

- **Containerized console.** The only file that runs on the host is `./tc`, whose sole dependency
  is the `docker` binary. The menu and its whole toolchain live in a ~200 MB image.
- **Guided setup** with per-answer validation, a review screen, and no writes until you confirm.
- **Generated compose stack** — server, PostgreSQL 17, and one explicit service per agent so each
  keeps its own configuration volume and therefore its own authorization token.
- **Three backup tiers** — TeamCity-native, logical (`pg_dump`), and cold — with retention, a
  disk-space guard, and restore refusals for incompatible TeamCity version, database backend or
  PostgreSQL major.
- **Guarded upgrades** that refuse downgrades, force a backup first, and surface the one-time
  maintenance token TeamCity prints only to its log.
- **`./tc token`** reads the super user token out of the log volume — where TeamCity's own
  instructions dead-end inside a container — and verifies it against the server before showing it.
- **Logging** — one file per tool under `logs/`, with session ids, secret redaction and rotation.
- **`./tc doctor`**, **`./tc verify`**, and a diagnostics bundle.
- **`Makefile`**, including `make perms` for checkouts that lost file modes.
- 92 `bats` tests and `shellcheck`, both self-contained in the console image.

### Notes on correctness

Several defects found during development are worth recording, because the same shapes recur in
tools of this kind:

- Every `VOLUME` the images declare is mapped. The server declares 3 and the full agent 8; an
  unmapped one becomes an anonymous volume, silently discarding agent caches on each recreate.
- `TZ` is set on every container. The agent image hardcodes `Europe/London`.
- The readiness probe distinguishes "starting" from "up but awaiting first-run setup", because
  TeamCity answers **503** on `/login.html` until the licence is accepted.
- `gum spin` execs its argument and cannot run a shell function. A pseudo-terminal test harness
  now covers the interactive branch, which behaves differently from the piped one.

### Removed before release

- **Agent auto-authorization.** Implemented against TeamCity's documented
  `teamcity.agentAutoAuthorize.authorizationToken`, then removed: the server reads the property but
  agents presenting the matching token still register as Unauthorized, and forcing the token into
  an existing agent's configuration makes the server treat it as a different agent. Authorization
  is explicit; see [docs/tools/agents.md](docs/tools/agents.md).

### Added after tagging

- **`./tc admin`** — creates the first administrator over REST and grants it `SYSTEM_ADMIN`,
  automatically when the server comes up with no accounts. A started TeamCity with zero users
  answers 200 and looks healthy while being impossible to sign in to.

### Verified

- The **native backup** round-trip (`./tc verify --deep`) runs against a live server: REST-initiated
  archive, copied out of the data directory, manifest written, cleaned up.
- **Agent authorization** over REST, using the super user token — no personal access token needed.

### Known limitations

- Only macOS/arm64 has been exercised. Linux and WSL 2 support comes from removing non-portable
  tooling and from tests asserting those absences — see [docs/platforms.md](docs/platforms.md).

[0.2.0]: https://github.com/simtabi/teamcity-installer/releases/tag/v0.2.0
[0.1.0]: https://github.com/simtabi/teamcity-installer/releases/tag/v0.1.0
