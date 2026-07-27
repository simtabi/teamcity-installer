# Restore from a backup

Replace the current stack with the contents of an archive.

```sh
./tc restore
```

Pick an archive; its manifest is shown before anything happens, and you must type the stack name to
confirm. The stack is then brought `down`, each volume wiped and repopulated, and started again.

## If it refuses

Three combinations are rejected up front, because each would otherwise produce a server that will
not start and an error that does not explain why.

**Different database backend**

```
error  The archive holds a 'hsqldb' stack; this one runs 'postgres'.
```

Only a **native** archive moves between backends. See [switch to PostgreSQL](switch-to-postgres.md).

**Newer TeamCity version**

```
error  The archive is from TeamCity 2027.1; this stack runs 2026.1.3.
```

A data directory written by a newer server will not load on an older one. Set `TC_VERSION` to the
version named and try again.

**PostgreSQL major mismatch** (cold archives only)

```
error  Cold archive holds a PostgreSQL 16 data directory; this stack runs 17.
```

A raw data directory does not load across major versions. Either set `TC_PG_VERSION` to match, or
use a logical or native archive, which replay into any major.

## Listing archives

**Backup → List** shows kind, TeamCity version, PostgreSQL major, size and date for everything in
`backups/`.

---

[← Docs index](../../README.md#documentation)
