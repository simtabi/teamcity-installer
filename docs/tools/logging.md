# Logging

The console's own record: one file per tool under `logs/`, with redaction and rotation.

`./tc logs` shows the **containers'** logs. This is the console's own behaviour — what it decided,
what it ran, and why it refused. Without it a failure leaves only whatever scrolled past, and the
next menu redraw takes even that away.

## Reading it

```sh
./tc journal            # choose a tool
./tc journal stack      # one tool
./tc journal stack follow
./tc journal all        # every tool, interleaved by timestamp
```

Or **Journal** in the menu. `make journal TOOL=stack` does the same.

## Layout

```
logs/
├── console.log      session start, command dispatch, unexpected failures
├── wizard.log       answers accepted and rejected, with the reason
├── stack.log        up / down / restart / status, and every compose command run
├── agents.log       scale, authorize, prune
├── backup.log       backup, restore, retention pruning
├── upgrade.log      version changes, guard refusals
├── doctor.log       probe results
└── verify.log       per-check pass / fail / skip
```

Files appear as tools are used; an unused tool has no file rather than an empty one.

## Format

```
2026-07-27T13:45:02-0400  INFO   a3f1  stack.up         teamcity     compose up --detach
└ timestamp               └ level └ id  └ tool.action    └ stack      └ message
```

Column-aligned so it reads down the page, single-space delimited so `cut` and `awk` work.

The **session id** is fixed for one `./tc` invocation, so a single run can be isolated even when
runs interleave:

```sh
grep a3f1 logs/*.log | sort
```

## What is captured

- Every command dispatch and its exit code.
- **Every `docker compose` command actually executed.** `stack::compose` is the choke point every
  call passes through, so the exact argv is recorded — worth more than any amount of prose when
  reconstructing a failure.
- Every message the console shows you. `ui::ok`, `ui::warn` and `ui::err` emit log lines, so the
  record matches what you saw.
- Guard refusals, readiness transitions, retention pruning, lock waits.

## Redaction

Secrets must never reach these files. Unlike the diagnostics bundle, which is assembled on demand,
this surface writes continuously — a secret that lands here stays here.

Two layers:

1. **Known values** — the configured database password and the stored access token are replaced
   wherever they appear.
2. **Shape** — anything matching `password=`, `token=`, `Bearer …` or `POSTGRES_PASSWORD=` is
   masked regardless of origin.

Both become `«redacted»`, and the surrounding message is preserved so the line still reads:

```
connecting with password=«redacted» to the database
```

A test asserts the configured password never appears in any log file after a run. That is a
release gate, not a nicety.

## Rotation and level

| Setting | Default | Effect |
|---|---|---|
| `TC_LOG_LEVEL` | `INFO` | `DEBUG`, `INFO`, `WARN`, `ERROR` or `OFF`. `DEBUG` adds every command executed. |
| `TC_LOG_MAX_KB` | `2048` | A file rotates to `.1` past this size. |
| `TC_LOG_KEEP` | `5` | How many rotations survive. |

Rotation is size-based and needs no external tooling, so logs cannot repeat the unbounded growth
that backups originally had.

Logging never fails the operation it describes: an unwritable `logs/` is ignored rather than
aborting a backup.

## In a bug report

`logs/` is included in the diagnostics bundle (`Doctor → Export bundle`), post-redaction. It is
usually the fastest route from "it broke" to what actually ran.

`logs/` is gitignored.

---

[← Docs index](../../README.md#documentation)
