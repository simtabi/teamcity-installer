# Doctor

Diagnostics: one screen answering "why isn't this working?" without needing to know which `docker`
command to reach for.

```sh
./tc doctor
```

## What it checks

**Docker** — daemon version, Compose version, architecture, CPU and memory available to the VM.

**Containers** — every service with its state, health and uptime.

**HTTP** — the status code, interpreted rather than reported raw:

| Reported | Means |
|---|---|
| `200, ready` | fully up and set up |
| `503, up but awaiting first-run setup` | running; run `./tc token`, then accept the licence and create the admin account |
| `no response` | still starting, or not running |

The middle case matters. On a fresh install TeamCity answers 503 on `/` and `/login.html` until the
licence is accepted, and only `/mnt` returns 200. A plain "is it 200?" check would call a healthy
server broken for exactly as long as it takes you to click through setup.

**Database** — PostgreSQL version, whether it is accepting connections, and the database size.

**Agents** — configured, known, connected and authorized counts. Warns when the authorized count
exceeds the free licence (the build queue is paused), and when fewer agents are connected than
configured — with the `SERVER_URL` hint, since pointing an agent at `localhost` is the usual cause.

**Volumes** — how many of the expected named volumes exist, and overall volume usage.

**Anonymous volumes** — scoped to this stack's own containers, not the whole daemon. A non-zero
count means one of the images declares a `VOLUME` the renderer is not mapping, so its contents are
being discarded on every recreate. This is a regression check for the stack's most subtle failure
mode; see [architecture](../architecture.md).

**Server log** — the last 50 lines, but only when the stack is not fully running, so a healthy run
stays readable.

## Diagnostics bundle

**Doctor → Export bundle** writes a directory under `backups/` containing `docker info`, the
container list, volume list, disk usage, 2000 lines of combined logs, the rendered compose file and
a redacted `.env`.

Safe to share: the database password is redacted and the REST access token is never included,
because it lives in `stack/.secrets` rather than `.env`.

---

[← Docs index](../../README.md#documentation)
