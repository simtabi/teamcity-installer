# Switch to PostgreSQL

Move a stack from the bundled HSQLDB to a PostgreSQL container.

Changing `TC_DB` does not migrate anything — the two databases hold entirely separate data. Move
the data with a **native** backup, which is the only tier that crosses database backends.

```sh
./tc backup native        # needs the server running and a stored access token
$EDITOR stack/.env        # TC_DB='postgres', set TC_PG_PASSWORD
./tc reset                # destroys the HSQLDB stack
./tc up                   # creates the PostgreSQL stack
./tc restore              # pick the native archive
```

`TC_PG_PASSWORD` must be at least 16 characters and cannot contain `$`, backticks, quotes or
backslashes — they break `.env` interpolation and the JDBC URL. Generate one with:

```sh
openssl rand -base64 64 | tr -dc 'A-Za-z0-9._-' | cut -c1-32
```

On the next start, `datadir-init` downloads the PostgreSQL JDBC driver, verifies it against Maven's
published SHA-1, writes `config/database.properties` and hands the data directory to uid 1000. As a
result TeamCity's own setup **skips the database step** entirely.

Starting fresh instead of migrating? Just reset and run the wizard, which offers PostgreSQL as the
default.

---

[← Docs index](../../README.md#documentation)
