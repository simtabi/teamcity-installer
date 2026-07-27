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
| Agents | scale, list, authorize, prune — see [agents](agents.md) |
| Backup | back up, restore, list — see [backup](backup.md) |
| Upgrade | change TeamCity version — see [upgrade](upgrade.md) |
| Doctor | diagnostics — see [doctor](doctor.md) |
| Verify | live end-to-end checks — see [verify](verify.md) |
| Token | print the super user token for TeamCity's first-run setup |
| Open | print the URL (the console is a container and cannot open a browser) |
| Shell | `exec` a shell in a running container |
| Reconfigure | re-run the wizard with current values prefilled |
| Reset | destroy the stack and every volume it owns |

A failure inside any action reports the file, line and command, then returns to the menu.

## Commands

Every menu action has a non-interactive equivalent:

```sh
./tc install             # guided setup
./tc up                  # start
./tc down                # stop
./tc restart
./tc status              # non-zero exit when not fully running
./tc logs [service]
./tc agents              # list
./tc authorize           # authorize all pending agents
./tc backup [native|logical|cold]
./tc restore
./tc upgrade
./tc doctor
./tc verify [--deep]     # live end-to-end checks
./tc token               # super user token, for first-run setup
./tc preflight
./tc reset
./tc lint                # shellcheck, inside the container
./tc --help
```

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

89 tests, and the suite is **pure**: `docker` and the network are stubbed, so it needs no daemon,
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
| `portability.bats` | `tc` stays free of GNU-only and Perl-only dependencies |

Each file names the bug that motivated it. `volumes.bats` exists because a shipped version mapped
`/var/lib/docker` only under Docker-in-Docker, leaking three anonymous volumes on a default stack;
`config.bats` exists because `.env` was once `source`d, so `TC_MEM_OPTS=-Xmx2g -XX:…` tried to
execute its second word.

## Locking

Lifecycle commands take an exclusive `flock` on `stack/.lock`, so two `./tc` invocations cannot
interleave a re-render with an `up`. The second waits and says so.

---

[← Docs index](../../README.md#documentation)
