# Platforms

Where this runs, what was done to make that true, and — plainly — what has actually been tested.

## Support

| Platform | Status |
|---|---|
| macOS, Apple Silicon | developed and tested here, including a full first-run and restore |
| Linux, x86-64 | a full stack stood up and verified in CI on every scheduled run — see below |
| macOS, Intel | expected to work; same code path, different image architecture |
| Linux, arm64 | expected to work; same code path as x86-64, which is exercised |
| Windows via WSL 2 | expected to work; portability asserted by tests, not run on a real host |
| Windows without WSL | not supported |

> **What "tested" means here, precisely.**
>
> **macOS/arm64** is where this was developed: full first-run, upgrade, backup, restore and reset.
> The upgrade path was exercised end to end against a throwaway stack — 2025.11.7 pulled, booted,
> then upgraded to 2026.1.3: the mandatory pre-upgrade backup, the re-render, the pull, container
> recreation, the maintenance watcher, and the printed token confirmed accepted by TeamCity's own
> `/mnt/do/authenticate` (and a wrong one rejected). Both agent Docker modes were run the same way.
>
> One part of that is still unproven: TeamCity's *data directory upgrade* confirmation specifically.
> Reaching it needs a server whose first run was completed, and completing a first run means
> accepting the licence agreement — which this tool will not do on your behalf. The rehearsal
> therefore stopped at the licence stage, which is the same maintenance page and the same token;
> what has not been observed is TeamCity's own upgrade-confirmation wording.
>
> **Linux/x86-64** is exercised by the `e2e` CI job, which stands the stack up from nothing on
> `ubuntu-latest` and runs the live checks against it. As of the first run: 12 volumes with none
> anonymous, the timezone applied, PostgreSQL accepting connections, `database.properties` seeded,
> the data directory writable by uid 1000, and a 321 MB cold backup taken. That job also covers the
> **minimal agent image**, which correctly maps 7 volumes rather than 8.
>
> It stops at TeamCity's licence agreement, which cannot be accepted unattended — so the REST,
> agent-authorization and native-backup checks skip there. Everything up to that gate is proven on
> Linux; everything past it is proven only on macOS.
>
> **WSL 2** is still unexercised. Support for it comes from removing every tool and flag that is not
> universally present, and from tests asserting those absences — `tc` parses under both POSIX `sh`
> and busybox `ash`, and is checked for `shasum`, `sort -z` and GNU-only flags. That guards the
> usual portability failures; it is not the same as having been run there. Reports welcome.

## Why the risk is concentrated in one file

Everything under `console/lib` runs inside the Alpine console image with GNU coreutils, so it sees
the same environment everywhere. The only thing that executes on *your* machine is `./tc`, and it
uses nothing but `docker` plus a few shell builtins.

That is the whole portability surface — one file, checked by `portability.bats`.

## What was needed for each platform

**Hashing.** `./tc` fingerprints `console/` to decide whether to rebuild the image. macOS ships
`shasum` (a Perl script); many Linux images have no Perl but do have `sha256sum`. The launcher
tries `sha256sum`, `shasum`, `sha1sum`, `md5sum`, then `cksum`. Any of them will do — the hash only
has to be stable on one machine.

**Sorting.** `sort -z` is absent from busybox. The file list is sorted as ordinary lines under
`LC_ALL=C`.

**Timezone.** Containers must agree with your clock, because the TeamCity agent image hardcodes
`TZ=Europe/London`. Three sources are tried in order: `$TZ`, `/etc/timezone` (Debian and most WSL
distributions), then the `/etc/localtime` symlink (macOS, systemd Linux). WSL commonly has
`/etc/localtime` as a *copy* rather than a symlink, which is why the symlink route alone silently
produced UTC there.

**The Docker socket.** Never hardcoded. Resolved from `docker context inspect`, falling back to
`$DOCKER_HOST` and then `/var/run/docker.sock`. This matters on macOS with OrbStack, where the
socket is at `~/.orbstack/run/docker.sock` and the classic path may not exist at all.

**The socket's group, for agents.** With `TC_AGENT_DOCKER='socket'` the agent must belong to the
group that owns the socket, and that group is not the same everywhere — root on OrbStack and
Docker Desktop, a distribution-specific docker group on Linux. It is read at render time rather
than assumed, so the compose file is correct for the machine that generated it. See
[enable Docker builds](recipes/enable-docker-in-docker.md).

**`host.docker.internal`.** Present by default on Docker Desktop and OrbStack, absent on plain
Linux. The launcher always passes `--add-host host.docker.internal:host-gateway`.

## WSL specifics

Use **WSL 2** with Docker Desktop's WSL integration enabled, or Docker Engine installed inside the
distribution.

**Keep the project on the Linux filesystem.** A checkout under `/mnt/c/...` is reached through the
9p bridge and is markedly slower for the file-heavy work here. `./tc` detects a `/mnt/` path and
says so. Prefer `~/teamcity-installer`.

**Line endings.** A checkout with `core.autocrlf=true` writes CRLF, and a CRLF shebang fails with
`bad interpreter: /bin/sh^M` — an error that never mentions line endings. `.gitattributes` pins
`eol=lf` for every script, and `make perms` repairs a checkout that arrived wrong anyway.

**Executable bits.** Windows-mounted filesystems do not carry them. `make perms` restores them, and
every `make` target that runs `./tc` depends on it, so a fresh clone works without anyone having to
know.

## Checking your own machine

```sh
make preflight
```

It reports the Docker daemon, Compose version, image architecture, VM memory, free disk and port
availability, with a specific remedy for anything it does not like.

---

[← Docs index](../README.md#documentation)
