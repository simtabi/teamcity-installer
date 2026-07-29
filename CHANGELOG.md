# Changelog

Notable changes to this project. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versioning follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.4.1] — 2026-07-29

### Added

- **`./tc backup list`** (and `make backup KIND=list`). The listing existed from the start and was
  reachable only from the menu, so nothing could script it — the same gap that once left `shell`,
  `open`, `reconfigure` and `prune` menu-only. A test now asserts every kind the error message
  advertises is actually dispatched.

## [0.4.0] — 2026-07-29

The same defect had been fixed three times in three modules. This release fixes the cause instead
of a fourth symptom. See [why one place owns each fact about the
server](docs/architecture.md#why-one-place-owns-each-fact-about-the-server).

### Changed

- **One place decides what a not-ready server is waiting for.** `stack::server_state` returns three
  values for a domain with six distinguishable conditions, so every caller needing more re-derived
  the difference from context it did not have. Six had independently settled on "awaiting first-run
  setup" — right for one of the six, wrong for four. `stack::not_ready_reason` and
  `stack::server_failed` now answer both questions once, from TeamCity's own published stage, and
  `admin`, `doctor`, `verify`, `status` and the post-`up` guidance all read them.
- **One place orders archives.** The listing and the restore chooser each carried their own
  `find | sort`, which orders by kind rather than by date — presenting an older archive above a
  newer one in a menu chosen from by position. Both now use the ordering retention already had.

### Added

- **Structural tests against a repeat.** No module outside `stack.sh` may state what a not-ready
  server wants; no code outside `backup::_archives_oldest_first` may order archives; a startup
  failure is detected in exactly one place. Each was checked by reintroducing the original bug and
  confirming the suite goes red.

### Fixed

- `./tc doctor` and `./tc admin` described a server that had failed to start as one awaiting
  first-run setup, and pointed at `./tc token` rather than the server log.

## [0.3.2] — 2026-07-29

### Fixed

- **A booting server was treated as one awaiting first-run setup.** TeamCity serves its maintenance
  page from the moment it has a web connector, including while it is still starting its own
  components, so answering there says nothing about whether it wants anything. A stack restored
  from a backup — licence long accepted, administrator already present — was told to accept a
  licence and create an administrator, and handed a super user token to do it with, purely because
  it had not finished booting. The page publishes `Stage: APPLICATION_STARTING`; that is now read
  and reported as *starting*. Everything downstream inherits the correction: `verify`, the upgrade
  watcher, and the guidance printed after `up` and after a restore.

## [0.3.1] — 2026-07-29

### Fixed

- **Retention deleted the newest archive, not the oldest.** `find | sort` orders paths as strings
  and every archive name begins with its kind, so every `teamcity-cold-…` sorted ahead of every
  `teamcity-logical-…` whatever the dates were. Walking that list from the front and calling each
  one the oldest meant a limit of two, applied to four archives, would have removed a cold snapshot
  taken minutes earlier and kept a logical one from the morning. Chronology only ever held within a
  single kind. Ordering is now taken from the timestamp the name already carries.

## [0.3.0] — 2026-07-29

Four paths that were documented but had never been executed — both agent Docker modes, the upgrade,
the disk guard and WSL — were run for the first time. Each one was broken in a way no amount of
reading would have shown.

### Fixed

- **Host-socket agent mode never worked.** The compose file was right — socket mounted, agent
  connected and authorized — and every `docker` command in a build failed with *permission denied*.
  The agent runs as uid 1000 with a `docker` group of its own (GID 999 in JetBrains' image) while
  the socket belongs to the host's group: root on OrbStack and Docker Desktop, a distribution
  group on Linux. The agent is now granted the socket's actual group, read at render time.
- **An upgrade announced the wrong step.** Whenever the server sat in setup state it said "confirm
  the data directory upgrade" — but TeamCity serves the same 503 maintenance page for the licence
  agreement, a data directory upgrade and the first administrator. It now reads the stage TeamCity
  publishes in the page and repeats its description verbatim, and says nothing invented when the
  marker is absent.
- **The logical backup had no disk guard**, though it writes gigabytes and stops the server partway
  through. Filling the disk there left a stopped server and a truncated archive. It is now checked,
  sized on the two volumes it actually writes rather than all twenty-nine.
- **Backup retention could delete another stack's archives.** Names carry no stack — every archive
  is `teamcity-<kind>-<stamp>` whatever `TC_STACK` is — so a second stack sharing the checkout
  counted its backups against the same limit and pruned the first stack's, oldest-first. The owner
  is now read from each archive's manifest; an unattributable archive is left alone and reported.
- **The console image tag could be invalid.** `cksum` — the last resort where no other hasher
  exists — prints `<checksum> <bytes>`, and the space fell inside the twelve characters the
  launcher truncates to, producing `363105736 13` and a build that dies with `invalid reference
  format`. The hash is reduced to alphanumerics before the cut.
- **`./tc verify` aborted instead of reporting** once `docker container prune` had collected the
  exited `datadir-init` container — it exits immediately by design, so it is the first thing a
  prune takes. An uninitialised local killed the run under `set -u` with `code: unbound variable`.
- **A server that failed to start was reported as a pass**, "awaiting first-run setup", while
  TeamCity was showing a startup error. Both answer 503 with a maintenance page; verify now
  distinguishes them and gives the cause.
- **The Docker memory probe crashed the validator** when the daemon was unreachable: `docker info
  --format` prints its own `0` *and* exits non-zero, so the fallback appended a second line and
  `(( ))` died with a bash syntax error — thrown at the user in exactly the situation already going
  wrong.

### Changed

- `./tc restore` shows the owning stack for each archive and confirms before restoring across
  stacks — legitimate when cloning an instance, never something to do by accident.
- The native backup is documented as deliberately unguarded: TeamCity's own archive is a fraction
  of the data directory (1.4 MB against 3 GB of volumes), and guarding it by the same rule would
  refuse the one backup that still fits when disk is short.
- `make verify-deep` is described accurately. It removes the time limit on the backup check; it
  does not add checks.

### Verified

- **Docker-in-Docker**: privileged, sudo image, inner daemon with a *different* daemon id to the
  host, its own layer volume, a container actually run inside it.
- **Host socket**: agent reaches the host daemon and runs a container against it.
- **Upgrade**: 2025.11.7 booted and upgraded to 2026.1.3 on a throwaway stack — mandatory backup,
  pull, recreation, maintenance watcher, and the printed token confirmed accepted by TeamCity's own
  `/mnt/do/authenticate` (a wrong one rejected). The revert path was exercised with a version that
  does not exist.
- **Disk guard**: refused against a real 64 MB filesystem, with `df` and `du` reporting honestly;
  both backup kinds returned non-zero with container ids unchanged and no archive written.
- **WSL 2**: `./tc` run from a WSL-shaped Ubuntu host — dash as `/bin/sh`, `/etc/localtime` a
  regular file, no `shasum`, a remote daemon. The timezone resolved from `/etc/timezone` (`+0900`
  with a New York copy at `/etc/localtime`), a CRLF checkout failed and `make perms` repaired it,
  and the `/mnt/c` note fired before anything slow.

### Known limitations

- **macOS/arm64 is the only platform genuinely run on.** Linux/x86-64 is exercised in CI up to
  TeamCity's licence gate. WSL 2 has been run only in a container shaped like it — a real Windows
  kernel, the 9p bridge and Docker Desktop's integration remain unproven.
- **TeamCity's data-directory-upgrade confirmation has not been observed.** Reaching it needs a
  server whose first run was completed, and that means accepting the licence agreement — which this
  tool will not do on anyone's behalf. See [docs/platforms.md](docs/platforms.md).

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

[0.4.1]: https://github.com/simtabi/teamcity-installer/releases/tag/v0.4.1
[0.4.0]: https://github.com/simtabi/teamcity-installer/releases/tag/v0.4.0
[0.3.2]: https://github.com/simtabi/teamcity-installer/releases/tag/v0.3.2
[0.3.1]: https://github.com/simtabi/teamcity-installer/releases/tag/v0.3.1
[0.3.0]: https://github.com/simtabi/teamcity-installer/releases/tag/v0.3.0
[0.2.0]: https://github.com/simtabi/teamcity-installer/releases/tag/v0.2.0
[0.1.0]: https://github.com/simtabi/teamcity-installer/releases/tag/v0.1.0
