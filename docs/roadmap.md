# Roadmap

Where this is going, and the one decision large enough to be a major version.

## v1 — where we are

A containerized control console for a single-node TeamCity stack: guided setup, lifecycle, agent
management, three backup tiers, guarded upgrades and diagnostics. Roughly 2,400 lines of bash
shipped as a ~200 MB Alpine image, driven by a launcher whose only host dependency is `docker`.

Correctness is held by two suites: `./tc test` (47 bats cases, pure — no daemon, no network) and
`./tc verify` (live end-to-end against a running stack).

## v2 — a Go rewrite, when it is warranted

**Not now.** The decision has been made once, deliberately, and this section records it so it is
not re-litigated from scratch every time the tool grows.

### Why bash won for v1

Go's headline advantage is a single static binary with no runtime dependencies. That advantage is
**already delivered** here by shipping as a container image — there is nothing to install and
nothing to distribute, so the main reason to reach for Go evaporates before the argument starts.

Beyond that:

- Roughly 70% of the code invokes `docker` / `docker compose` and formats the output. That is
  bash's home turf; in Go it would be `os/exec` calls wrapped in more ceremony.
- Embedding Compose as a library is possible — `github.com/docker/compose/v2/pkg/api` is a real,
  versioned package — but it pins you to one Compose implementation instead of using whatever the
  user's Docker ships, and drags in a large dependency tree.
- This is an ops tool people fork and tweak. A shell script lowers that barrier; a Go project
  raises it to "install a toolchain first".

### What bash actually cost

Being honest about the other side: every bug found during development was bash-specific.

| Bug | Would Go have prevented it? |
|---|---|
| Unquoted regex operand split on a space, making a validator a syntax error | Yes |
| `source`-ing `.env` executed its contents; a value with spaces ran as a command | Yes |
| Trailing `&&` made a function return non-zero — hit **twice**, once aborting a render and once reporting a successful backup as failed | Yes |
| `/var/lib/docker` mapped only under Docker-in-Docker, leaking anonymous volumes | No — logic, not language |
| Readiness probe treated TeamCity's 503 setup page as "down" | No — domain, not language |

Three of five. Real, and the trailing-`&&` shape recurred in a second place months of eyeballing
would not have caught — it only manifests on the HSQLDB path, where the guarded variable is empty.

But they point at a **missing test suite** rather than a missing type system, and that has since
been addressed far more cheaply. `./tc test` now covers exactly the logic where these mistakes were
silent, including a structural check that no function ends in a bare conditional-and, and each
guard is proven by reintroducing the bug and watching it fail.

### Triggers for reconsidering

Revisit Go when **any** of these become true. Until then, the answer stays no.

1. **A long-running daemon.** Anything that must hold state between invocations — watching agents,
   scheduling backups, reconciling drift — stops being a script. Bash has no story for that.
2. **Real concurrency.** Managing many stacks, or agents, in parallel with coordinated
   cancellation. Backgrounding and `wait` do not scale to this, and the failure modes are subtle.
3. **A state machine.** Multi-step operations that must resume after interruption — a partially
   applied upgrade, a half-finished migration. That needs persisted state and typed transitions.
4. **Beyond a single node.** TeamCity multi-node, or orchestrating several stacks with shared
   config, multiplies the data modelling past what associative arrays carry comfortably.
5. **Sustained growth past ~4,000 lines.** 2,400 is manageable with tests. Double it and the
   absence of types, modules and refactoring tools starts to dominate.

None are on the horizon.

### What v2 would look like

Recorded so the work is scopeable if a trigger fires:

- **TUI**: Bubble Tea rather than gum. Same authors — gum *is* Bubble Tea components exposed as
  one-shot CLI widgets — so this is a step up in capability, not a change of ecosystem. It would
  buy live-updating status, scrollable logs and real progress, which one-shot widgets cannot do.
- **Docker**: keep shelling out to `docker compose`. The CLI is the stable contract; the library
  is not worth the coupling.
- **Ported first**: the validators, the renderer, manifest compatibility and version ordering —
  the pure logic already isolated by the bats suite, which doubles as the acceptance criteria for
  the port.
- **Kept**: the container-first delivery. A Go binary would still ship inside the console image,
  because the argument for containerizing the tooling is independent of the language.

The bats suite is the migration spec: a port is done when it passes the same cases.

## Smaller things, no version bump needed

- TeamCity multi-node — would likely trip trigger 4 on its own.
- `./tc verify` gaining coverage as more of the surface becomes automatable.
- A CI workflow running `./tc lint` and `./tc test` on every change, and `./tc verify`
  against an ephemeral stack.

---

[← Docs index](../README.md#documentation)
