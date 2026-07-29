# Smoke build

Proving the stack can build something, rather than that it looks healthy.

```sh
./tc smoke                # or: make smoke
./tc verify --deep        # includes it, alongside the other 18 checks
```

## Why it exists

Every other check this console makes is a **precondition**. Containers healthy, 29 volumes mapped,
the timezone applied, PostgreSQL accepting connections, REST answering, three agents connected and
authorized — all necessary, none of it evidence that a build will run.

A CI server that cannot execute a build step is broken no matter how green its status page is. For
most of this project's life every check passed and nobody had ever asked the server to build
anything.

## What it does

1. Refuses early if no agent is **connected and authorized** — a build with nowhere to run would
   otherwise sit in the queue until the timeout, and "timed out after 300s" sends you looking in
   entirely the wrong place.
2. Creates a throwaway project and build configuration with one command-line step. No VCS root:
   checking out a repository would test network access to somewhere else, not this stack.
3. Queues a build and waits, reporting TeamCity's own `waitReason` while it is queued rather than
   just how long it has been waiting.
4. Asserts three things, and **deletes the project on every exit path**, including failure.

```
ok  Build #2 succeeded on teamcity-agent-1-1 (Linux aarch64).
    The step ran and its output is in the build log — not just a green status.
    Removed the smoke-test project.
```

## The assertion that matters

The build must finish, it must report `SUCCESS`, **and a marker string generated for this run must
appear in the log the agent produced**.

The third is the point. A build whose step silently never executed still reports success, so
checking the status alone would confirm TeamCity's opinion of itself. The marker is timestamped per
run, so a log from an earlier build cannot satisfy a later check.

Verified by asserting a marker against a genuinely successful build that could not contain it:

```
error  The build reported success but its step produced no output.
       The marker 'a-marker-that-never-existed' is absent from the build log, so the
       command did not actually run on the agent.
```

## Timing

`SMOKE_TIMEOUT` (default 300 seconds) bounds the wait. Seconds on an idle stack — the first real
build here took 11 — but a busy server may queue behind other work.

## Related

- [verify](verify.md) — the 18 preconditions this one sits behind
- [agents](agents.md) — why an unauthorized agent means a build never starts

---

[← Docs index](../../README.md#documentation)
