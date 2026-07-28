# Verify

Live end-to-end checks against a running stack, and the reason they are a command rather than a
checklist.

```sh
./tc verify           # 18 checks, non-destructive
./tc verify --deep    # same, without the time budget on the backup check
```

## Why this exists

`./tc test` proves the logic. It cannot prove that the volumes really got mapped, that the
timezone really took, that TeamCity really skipped its database step, or that the REST paths work
against this particular build — those need a running stack.

Everything here was, at some point, verified by hand once and then forgotten. That is exactly the
kind of check that silently stops being true. Making it a command means it is re-run rather than
remembered.

Together the two suites cover the surface:

| | `./tc test` | `./tc verify` |
|---|---|---|
| Needs a daemon | no | yes |
| Needs a running stack | no | yes |
| Needs the network | no | no |
| Proves | the logic is right | the stack is actually in the state the logic intended |
| Speed | seconds | tens of seconds |

## What it checks

**Stack** — every service running; `datadir-init` exited 0; the server answers HTTP, and whether
that is `200 ready` or `503 awaiting first-run setup`.

**Volumes** — every expected named volume exists; **zero anonymous volumes** across the stack's
containers; and each agent maps its full set (8 for the full image, 7 for minimal). This is the
regression guard for the bug that shipped once — an unmapped `VOLUME` becomes an anonymous volume
and its contents are discarded on every recreate.

**Timezone** — every container's `TZ` matches `TC_TZ`. Unset, the agent image forces
`Europe/London` and every build timestamp is wrong with nothing to announce it.

**Database** — PostgreSQL accepting connections; the JDBC driver present in the data directory;
`database.properties` pointing at the stack network; the server log confirming it *"skipped asking
a user for DB settings"*; and that **uid 1000 can write the data directory**, which is what the
root-then-chown seeding order exists to guarantee.

**REST and agents** — the API reachable with the stored token; the server's reported build number;
every configured agent connected and authorized; and the authorized count within the free licence,
since exceeding it pauses the entire build queue.

**Backup** — takes a real native backup through REST, asserts the archive and its manifest exist,
then deletes what it made.

This runs by default, because it is not disruptive: TeamCity supports backing up a *running*
server, and measuring it here found zero non-200 responses throughout. It was previously gated
behind `--deep` with the note "briefly pauses the server", which was wrong — that cost belongs to
the cold and logical tiers, which stop containers.

What it does cost is time, so it runs under a budget (`VERIFY_BACKUP_TIMEOUT`, 120s) and reports
how long it took. Exceed the budget and it skips saying so; `--deep` removes the budget.

> Sizing this from the data directory was tried and abandoned: 2.1 GB there turned out to be 1.1 GB
> of caches and 1.0 GB of plugins, none of which the backup includes. The archive was 1.4 MB and
> the run took two seconds. Measuring the real cost beats predicting it badly.

JetBrains' caveat is consistency rather than availability — a backup taken while builds run can
capture them mid-update. That matters for a backup you mean to restore, not for proving the path
works.

## Skips are not passes

A check that cannot run yet reports `SKIP` with the reason and the command that unblocks it:

```
info    REST and agents
  SKIP REST API reachable                    first-run setup not finished
       -> Run ./tc token, then complete setup at http://localhost:8111
  SKIP agents authorized                     needs an administrator account
```

The exit code counts **failures only**, so an incomplete first-run setup does not read as a broken
stack. A genuine failure exits non-zero and names the fix.

## In a pipeline

```sh
./tc lint && ./tc test && ./tc up && ./tc verify
```

`lint` and `test` need neither daemon nor network. `verify` needs the stack up. Output is plain
when not attached to a terminal, so `PASS`/`FAIL`/`SKIP` lines are greppable.

---

[← Docs index](../../README.md#documentation)
