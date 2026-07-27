# Verify

Live end-to-end checks against a running stack, and the reason they are a command rather than a
checklist.

```sh
./tc verify           # 15 checks, non-destructive
./tc verify --deep    # adds a real native backup round-trip
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

**Backup** (`--deep` only) — takes a real native backup through REST, asserts the archive and its
manifest exist, then deletes what it made.

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
