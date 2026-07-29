# Console

The launcher, the interactive menu, and the non-interactive commands.

## `./tc`

A POSIX shell script and the only file that runs on your machine. Its sole dependency is `docker`.
On each invocation it:

1. Checks `docker` is on `PATH` and the daemon is reachable, with a specific message for each
   failure rather than a stack trace.
2. Resolves the daemon socket from `docker context inspect`, falling back to `$DOCKER_HOST` and
   then `/var/run/docker.sock`. It refuses `tcp://` and `ssh://` contexts, which cannot be
   bind-mounted.
3. Hashes `console/` and builds `teamcity-console:<hash>` if that tag is missing, then removes tags
   from earlier hashes. Content-hashing rather than timestamps means edits always rebuild and
   clones never rebuild spuriously.
4. Execs `docker run` with the socket, the project mounted at its own absolute path, the host
   timezone, and `-t` only when both stdin and stdout are terminals.

## Menu

Running `./tc` with no arguments opens the menu. Before a stack exists it offers only **Install**,
**Preflight** and **Quit**; afterwards the full set:

| Entry | Does |
|---|---|
| Start | render the compose file, `up -d`, wait for HTTP |
| Stop | `stop` — containers down, volumes untouched |
| Restart | re-render and force-recreate |
| Status | service table with state, health, restarts and ports |
| Logs | follow one service or all; Ctrl-C returns to the menu |
| Journal | this console's own logs, one file per tool — see [logging](logging.md) |
| Agents | scale, list, authorize, prune — see [agents](agents.md) |
| Backup | back up, restore, list — see [backup](backup.md) |
| Upgrade | change TeamCity version — see [upgrade](upgrade.md) |
| Doctor | diagnostics — see [doctor](doctor.md) |
| Verify | live end-to-end checks — see [verify](verify.md) |
| Token | print the super user token for TeamCity's first-run setup |
| Admin | create the first administrator account |
| Users | list accounts and set passwords — see [users](users.md) |
| Open | print the URL (the console is a container and cannot open a browser) |
| Shell | `exec` a shell in a running container |
| Reconfigure | re-run the wizard with current values prefilled |
| Reset | destroy the stack and every volume it owns |

A failure inside any action reports the file, line and command, then returns to the menu.

> **What is and is not covered by tests.** `tty.bats` allocates a real pseudo-terminal, so the
> styled branch — the one that shipped the worst bug in this project's history — is exercised rather
> than assumed. What is *not* automated is typing at the chooser: `script(1)` in the console image
> does not forward piped stdin into the pseudo-terminal, so gum blocks in raw mode until killed.
> Instead the tests check the property those keystrokes would have checked — that a selection comes
> back as the bare label rather than the padded line that was displayed, including when gum trims
> whitespace, and that abandoning the chooser selects nothing rather than the first entry. Walking
> the menu by hand remains the one thing only a person can do.

**Every action ends visibly.** When one finishes, a bordered prompt names it and waits for enter:

```
╭──────────────────────────────────────────────────────────────╮
│  Reset finished — press enter to return to the menu          │
╰──────────────────────────────────────────────────────────────╯
```

This used to be a single grey line, which after a screen of compose output was easy to miss — so a
completed command was indistinguishable from a stuck one. Only submenus and the two handlers that
own the terminal until you leave them (`Logs`, `Shell`) skip it, and a test enforces that list.

**Nothing waits in silence.** Any operation that can take more than a few seconds reports where it
is on a fifteen-second cadence:

```
        still waiting for TeamCity… 45s
        still waiting for agents to register… 30s
```

## Commands

Every capability is reachable three ways — command line, menu and `make` — because a capability the
CLI cannot ask for is one nothing can script, and that gap has appeared here more than once.

### Lifecycle

| Command | `make` | Does |
|---|---|---|
| `./tc install` | `make install` | guided setup; writes `stack/.env` |
| `./tc reconfigure` | `make reconfigure` | re-run the wizard with current values, keeping all data |
| `./tc up` (`start`) | `make up` / `make start` | render, `up -d`, wait for HTTP, authorize agents |
| `./tc down` (`stop`) | `make down` / `make stop` | stop containers; volumes untouched |
| `./tc restart` | `make restart` | re-render and force-recreate |
| `./tc reset` | `make reset` | **destroys** the stack and every volume it owns |

`start`/`stop` are aliases, so muscle memory from `docker compose` works.

### Looking at it

| Command | `make` | Does |
|---|---|---|
| `./tc status` | `make status` | service table; **non-zero exit** unless everything is running |
| `./tc logs [service]` | `make logs SERVICE=server` | container logs, followed |
| `./tc journal [tool] [follow]` | `make journal TOOL=stack` | this console's own logs — see [logging](logging.md) |
| `./tc doctor` | `make doctor` | diagnostics and health probes |
| `./tc verify` | `make verify` | live end-to-end checks |
| `./tc verify --deep` | `make verify-deep` | the same checks, plus a real build end to end |
| `./tc smoke` | `make smoke` | run a throwaway build and prove its step executed |
| `./tc preflight` | `make preflight` | is this machine ready — runs before a stack exists |
| `./tc open` | `make open` | print the URL; a container cannot open your browser |
| `./tc shell [service]` | `make shell SERVICE=db` | shell inside a running container |

`./tc verify --deep` removes the time budget on the native backup round-trip, and adds the one check
that asks what the server exists to answer: it runs a build. Everything else verify does is a
precondition — containers healthy, volumes mapped, agents authorized — and none of it is evidence
that a build will actually run. See [smoke](smoke.md).

### Accounts

| Command | `make` | Does |
|---|---|---|
| `./tc token` | `make token` | super user token, verified against the running server |
| `./tc admin` | `make admin` | create the first administrator (only when no accounts exist) |
| `./tc users` | `make users` | every account, and which can administer |
| `./tc users show <user>` | `make user-show USER=admin` | one account: roles, groups, last sign-in |
| `./tc users passwd <user>` | `make user-passwd USER=admin` | set a password — works when nobody knows one |
| `./tc admin reset [user]` | — | alias of `users passwd`, kept for habit |

See [users](users.md) for how a password is chosen and why it is verified before being reported.

### Agents

| Command | `make` | Does |
|---|---|---|
| `./tc agents` | `make agents` | connected, authorized and enabled state per agent |
| `./tc authorize` | `make authorize` | authorize every agent waiting for it |

Scaling and volume pruning live in the menu under **Agents** — see [agents](agents.md).

### Data

| Command | `make` | Does |
|---|---|---|
| `./tc backup` | `make backup` | cold backup — the default |
| `./tc backup cold` | `make backup KIND=cold` | every volume, stack stopped; the exact-restore tier |
| `./tc backup logical` | `make backup KIND=logical` | `pg_dump` plus the data directory; crosses PostgreSQL majors |
| `./tc backup native` | `make backup KIND=native` | TeamCity's own archive, taken against a **live** server |
| `./tc backup list` | `make backup KIND=list` | archives, newest first, with the stack that owns each |
| `./tc restore` | `make restore` | choose an archive and restore it |
| `./tc prune` | `make prune` | apply `TC_BACKUP_KEEP`, oldest first |
| `./tc upgrade` | `make upgrade` | move to another TeamCity version |

The three tiers differ in more than size — see [backup](backup.md).

### Development

| Command | `make` | Does |
|---|---|---|
| `./tc lint` | `make lint` | shellcheck, inside the container |
| `./tc test` | `make test` | the bats suite; no daemon, stack or network needed |
| `./tc --help` (`help`, `-h`) | `make help` | the command list |
| — | `make check` | lint + test + verify, and that the run changed no tracked file |
| — | `make perms` | restore executable bits and strip CRLF after a Windows checkout |
| — | `make drift` | fail if the working tree has uncommitted changes |
| — | `make clean` | remove stale console images and apply backup retention |

Tests hold the three surfaces together: every menu entry must name a function that exists, every
`make` target must map to a command, and every backup kind the error message advertises must be
dispatched. They exist because `backup list`, `shell`, `open`, `reconfigure` and `prune` were each
menu-only at some point — present, working, and impossible to script.

### Exit codes

| Code | Means |
|---|---|
| `0` | success |
| `1` | the operation failed, with a reason printed |
| `2` | the command or argument was not understood |

`./tc status` is the one to script against: non-zero unless every container is running.

> Measuring these through a pipe measures the *last* command in the pipe. `./tc status | tail` then
> reports the exit code of `tail`, which is almost always 0.

## Scripting

Output is plain — no escape sequences — whenever stdout is not a terminal or `NO_COLOR` is set:

```sh
if ./tc status >/dev/null 2>&1; then
    echo 'stack is up'
fi

NO_COLOR=1 ./tc status 2>&1 | grep server
```

`status` exits non-zero when the stack is not fully running, so it works directly in a condition.

The menu is unavailable without a terminal; `./tc` with no arguments and no TTY explains that and
suggests passing a command instead.

## Tokens

Two unrelated tokens are involved, and confusing them is the usual way to get stuck:

- **Super user token** — unlocks TeamCity's first-run maintenance page. `./tc token` reads it out
  of the server log. It rotates on every server restart and is never stored. On stdout it prints
  bare, so `./tc token 2>/dev/null` is scriptable.
- **Access token** — lets the console authorize agents over REST. You create it in the TeamCity UI;
  it is verified live and stored in `stack/.secrets` (mode 600), deliberately not in `.env`.

## Tests

```sh
./tc lint             # shellcheck, inside the container
./tc test             # bats, inside the container
./tc verify [--deep]  # live checks against the running stack
```

`lint` and `test` need no daemon, no stack and no network. `verify` exercises the running stack —
see [verify](verify.md).

247 tests, and the suite is **pure**: `docker` and the network are stubbed, so it needs no daemon,
no stack and no internet. It runs anywhere the console image runs and is fast enough to gate a
commit.

What it covers is deliberately narrow — the logic where a mistake is silent rather than loud:

| File | Guards |
|---|---|
| `volumes.bats` | every `VOLUME` the images declare is mapped by name, at any agent count, for both image variants |
| `config.bats` | `.env` round-trips values containing spaces, ignores malformed lines, and **cannot execute** |
| `validate.bats` | each validator's accept and reject sets; generated passwords always satisfy the password validator |
| `restore.bats` | the three restore-compatibility refusals, and that logical/native archives cross PostgreSQL majors |
| `upgrade.bats` | downgrade refusal, including that `2026.1.10` is newer than `2026.1.9` |
| `token.bats` | super user token extraction, against real log fixtures |
| `logging.bats` | routing, redaction, rotation, level filtering |
| `menu.bats` | every menu entry names a handler that exists |
| `tty.bats` | the gum branch, under a real pseudo-terminal |
| `exitcodes.bats` | no function ends in a bare conditional-and |
| `portability.bats` | `tc` stays free of GNU-only and Perl-only dependencies, and every hasher yields a valid image tag |
| `users.bats` | setting a password never needs one, and never claims success it has not checked |
| `backup.bats` | the disk guard refuses before anything is stopped, at the exact boundary |
| `secrets.bats` | no credential reaches a tracked file, a log or a diagnostics bundle |
| `smoke.bats` | a green build with no step output is a failure, not a pass |

Each file names the bug that motivated it. `volumes.bats` exists because a shipped version mapped
`/var/lib/docker` only under Docker-in-Docker, leaking three anonymous volumes on a default stack;
`config.bats` exists because `.env` was once `source`d, so `TC_MEM_OPTS=-Xmx2g -XX:…` tried to
execute its second word.

## Locking

Lifecycle commands take an exclusive `flock` on `stack/.lock`, so two `./tc` invocations cannot
interleave a re-render with an `up`. The second waits and says so.

---

[← Docs index](../../README.md#documentation)
