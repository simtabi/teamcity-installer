# Platforms

Where this runs, what was done to make that true, and — plainly — what has actually been tested.

## Support

| Platform | Status |
|---|---|
| macOS, Apple Silicon | developed and tested here |
| macOS, Intel | expected to work; same code path, different image architecture |
| Linux (x86-64, arm64) | expected to work; portability asserted by tests, not run on a real host |
| Windows via WSL 2 | expected to work; portability asserted by tests, not run on a real host |
| Windows without WSL | not supported |

> **What "tested" means here.** The suite runs on macOS/arm64. Linux and WSL support comes from
> removing every tool and flag that is not universally present, and from tests that assert those
> absences — `tc` parses under both POSIX `sh` and busybox `ash`, and is checked for `shasum`,
> `sort -z` and GNU-only flags. That is a real guard against the usual portability failures, but it
> is not the same as having been run on those hosts. Reports from either are welcome.

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
