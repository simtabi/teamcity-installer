# What destroys data, and what does not

A per-command answer, because "rebuild" means different things and only one command here is
destructive.

## The short answer

**Rebuilding does not destroy data.** Containers are disposable; your data is not in them. Every
piece of TeamCity state — the data directory, the database, agent configuration and caches — lives
in a **named Docker volume** that outlives any container built on top of it.

Only `./tc reset` deletes data, and it makes you type the stack name first.

## Per command

| Command | Containers | Volumes (your data) |
|---|---|---|
| `./tc up` / `make up` | created or recreated | **kept** |
| `./tc down` / `make down` | stopped | **kept** |
| `./tc restart` | destroyed and recreated | **kept** |
| `./tc upgrade` | recreated on a new image | **kept** (and backed up first) |
| Editing `stack/.env`, then any command | recreated as needed | **kept** |
| Rebuilding the console image | not touched at all | **kept** |
| `./tc backup` | briefly stopped | **kept** |
| `./tc restore` | recreated | **replaced** by the archive |
| Agents → Scale down | those agents removed | kept, unless you accept the offer to delete them |
| Agents → Prune volumes | — | **deletes** volumes no longer referenced |
| `./tc reset` | destroyed | **deleted** |

## Why recreation is safe

The compose file is generated from `stack/.env` and reapplied on every lifecycle command, so
containers are routinely destroyed and rebuilt. That is normal operation, not a repair.

Volumes are named after the stack — `teamcity_datadir`, `teamcity_pgdata`,
`teamcity_agent-1-conf`, and so on. Compose attaches the existing volume by name to whatever
container it creates. Nothing about replacing a container touches the volume's contents.

You can watch this directly:

```sh
docker volume ls --filter name=teamcity_    # before
./tc restart
docker volume ls --filter name=teamcity_    # identical
```

Agents keep their identity across a restart for the same reason: each one's authorization token
lives in its own `conf` volume.

## The two that do delete

**`./tc reset`** runs `compose down --volumes` and removes every volume the stack owns. It requires
you to type the stack name — a plain yes is not accepted — and it says what it will destroy first.
`backups/` is not touched.

**Agents → Prune volumes** removes volumes named for this stack that the current configuration no
longer references, typically left behind after scaling down. It lists them with creation dates and
also requires the typed confirmation, because such a volume may hold the only copy of an agent's
identity.

## Things that look destructive and are not

**Changing the TeamCity version.** `./tc upgrade` recreates containers on a new image and forces a
backup first. The data directory is upgraded in place — which is why downgrades are refused, since
an older server will not load it.

**Changing the port, timezone, memory or agent count.** These re-render the compose file and
recreate containers. Data is untouched.

**Rebuilding the console image.** It happens automatically whenever `console/` changes and has no
connection to your stack at all — different image, different container, no shared volumes.

**`docker system prune`.** Safe by default: it does not remove named volumes. `docker system prune
--volumes` is *not* safe — it removes unused ones, which includes yours whenever the stack is down.

## What a rebuild from scratch reproduces

`./tc reset` followed by `./tc up` was run end to end to check this, not inferred. From
`stack/.env` alone, unattended:

- the PostgreSQL container and its database
- the JDBC driver and `database.properties` seeded into the data directory
- the timezone on every container
- all 29 named volumes, with no anonymous ones
- the first administrator account
- authorization of every agent that connects

**One step cannot be automated: accepting TeamCity's licence agreement.** That is a legal act, and
this tool will not click through it on your behalf. Until it is accepted the server sits on its
maintenance page, and the administrator and agent steps — which do run automatically — wait behind
it.

So a fresh install is: `./tc up`, accept the licence in the browser using the token `./tc token`
prints, and everything else takes care of itself.

## If you want a safety net

```sh
./tc backup            # cold backup of every volume
make backup KIND=native  # TeamCity's own archive, the most portable
```

`TC_BACKUP_KEEP` (default 5) bounds how many are kept. See [backup](tools/backup.md).

---

[← Docs index](../README.md#documentation)
