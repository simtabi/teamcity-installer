# Backup

Three backup tiers, what each is good for, and the rules that stop an incompatible restore.

Everything lands in `backups/` — the one place runtime output reaches the host filesystem, because
a backup you cannot get at is not a backup.

## Choosing a tier

| Tier | Server | Portable across TeamCity versions | Across PostgreSQL majors | Across database backends |
|---|---|---|---|---|
| **Native** | must be running | yes | yes | yes |
| **Logical** | briefly stopped | yes | yes | no |
| **Cold** | stopped | no | **no** | no |

**Native** is TeamCity's own archive, taken through REST. It is the format JetBrains support will
ask for, and the only one that survives a change of database backend. Needs a stored access token.

**Logical** is `pg_dump -Fc` plus a tar of the data directory. A logical dump replays into any
PostgreSQL major, which a raw data directory does not.

**Cold** is a tar of every volume. Fastest and most complete — agent caches and all — but the
PostgreSQL data directory inside it is tied to the major version that wrote it.

If you are about to upgrade PostgreSQL, take a logical or native backup. Cold archives from a
`postgres:17` stack will not load into `postgres:18`, and the console refuses rather than letting
you find out from a database that will not start.

## Taking one

```sh
./tc backup              # cold (default)
./tc backup logical
./tc backup native
```

Or **Backup → Back up** from the menu.

Every archive is a directory containing the data, a `manifest.json`, the rendered compose file, and
a copy of `.env` with the password redacted — enough to understand it months later without
guessing.

```json
{
  "kind": "cold",
  "stack": "teamcity",
  "teamcity_version": "2026.1.3",
  "database": "postgres",
  "postgres_major": "17",
  "timezone": "Africa/Nairobi",
  "agents": 3,
  "created": "2026-07-27T12:15:07-04:00",
  "volumes": ["datadir", "logs", "..."]
}
```

## Retention and disk

Archives are around 1 GB each, so `TC_BACKUP_KEEP` (default 5) bounds them: after each successful
backup the oldest beyond that are removed, and each removal is named rather than done silently.
`./tc prune` (or `make clean`) applies the same policy on demand.

Before a cold backup the console estimates the volume sizes, compares them with the free space in
`backups/`, and refuses when it will not fit — showing both numbers:

```
error  Not enough free disk for this backup.
       volumes total    4.6GB
       estimated need   2.8GB (compressed, plus headroom)
       free in backups/ 1.4GB
```

Filling the disk halfway through a backup takes the running stack down with it, which is a worse
outcome than not starting.

## Restoring

**Backup → Restore**, or `./tc restore`. Pick an archive; the manifest is shown before anything
happens.

Three checks run first, each of which would otherwise produce a server that will not start and an
error that does not explain why:

- **Database backend mismatch** — a `hsqldb` archive into a `postgres` stack is refused, with a
  pointer to the native tier, which is the only one that crosses backends.
- **Newer TeamCity version** — a data directory written by a newer server will not load on an older
  one. Refused, naming the version to set.
- **PostgreSQL major mismatch** (cold only) — refused, with the choice between changing
  `TC_PG_VERSION` and using a portable tier.

Then it requires you to type the stack name, stops the stack with `down` — not `stop`, because
volumes cannot be rewritten while containers hold them — wipes each volume, repopulates it, and
starts up again.

Volumes are wiped rather than untarred over. Merging an archive into existing content produces a
state that matches neither.

> **Archives contain credentials.** `datadir.tgz` carries `database.properties`, and the PostgreSQL
> volume carries its own copy, both in plaintext. `config.env` alongside them is the same
> configuration in restorable form. Treat `backups/` as secret material; it is gitignored.

## What each restore actually does

**Cold** — stops the stack, wipes each volume, untars the archive over it.

**Logical** — restores the data directory from `datadir.tgz`, drops the PostgreSQL volume so the
database starts empty, then replays `database.dump` with `pg_restore`.

**Native** — hands the archive to TeamCity's own `maintainDB`, which has three preconditions the
console now satisfies for you:

1. The data directory's `config/` must be **empty**. It refuses to overwrite an existing
   configuration.
2. The target database settings file must exist **outside** that directory — which is why the
   console stages a `database.properties` on a separate mount. Putting it in the data directory is
   what makes `config/` non-empty, so the obvious approach is circular.
3. The target database must have **no tables**. The console drops and recreates the schema.

The JDBC driver is preserved through the wipe, since `maintainDB` needs it to reach PostgreSQL at
all.

All three were verified end to end against a live stack: user account, three authorized agents and
153 tables came back in each case.

## Credentials after a restore

An archive carries its own database credentials inside the restored
`database.properties`, and the PostgreSQL volume it came from expects those. `stack/.env` keeps
whatever it held before, so a restore used to leave the config claiming a password the database did
not have — harmless until the `pgdata` volume was ever recreated, at which point the two disagreed
and the server could not connect.

Restore now realigns `stack/.env` from the archive's own `config.env` and says so. Settings other
than credentials — port, agent count, version — are reported when they differ but never changed: a
restore should not move the port out from under a running system.

Older archives without `config.env` still work; the password is read out of the restored data
directory instead.

## Verifying a guard

Copy an archive, edit its manifest, and confirm the refusal:

```sh
cp -R backups/teamcity-cold-* /tmp/test && \
  jq '.postgres_major="16"' /tmp/test/manifest.json > backups/test/manifest.json
./tc restore
```

```
error  Cold archive holds a PostgreSQL 16 data directory; this stack runs 17.
       A raw PGDATA directory does not load across major versions.
       Either set TC_PG_VERSION=16, or restore a logical or native archive.
```

---

[← Docs index](../../README.md#documentation)
