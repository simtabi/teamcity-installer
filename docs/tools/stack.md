# Stack

The generated compose file: its services, its volumes, and the choices baked into it.

`stack/docker-compose.yml` is rendered from `stack/.env` before every lifecycle command. Do not
edit it — the next render overwrites it. Change `stack/.env` instead.

## Services

### `db`

`postgres:17-alpine`, present only when `TC_DB=postgres`.

- `pgdata:/var/lib/postgresql/data` — the real `PGDATA`. JetBrains' own compose sample mounts
  `/var/lib/postgresql/${PG_VERSION}/docker`, which is not `PGDATA`; a stack copied from it appears
  to work and loses the database on recreate.
- `-c max_connections=200` — TeamCity's pool is 50 and maintenance opens more; the PostgreSQL
  default of 100 leaves too little headroom.
- Not published to the host. It is reachable only from inside the stack network.
- `pg_isready` healthcheck; the server waits for it.

### `datadir-init`

A one-shot `alpine:3.22` container that prepares the data directory before the server starts. It
downloads the PostgreSQL JDBC driver (checksum-verified against Maven's `.sha1`, cached in a
volume), writes `config/database.properties`, and hands the tree to uid 1000.

Because both exist before TeamCity first runs, the web setup wizard **skips the database step**.

It is idempotent: an existing `database.properties` is left alone, so a restart never overwrites a
configuration you have since edited.

See [architecture](../architecture.md) for why it runs as root and chowns last.

### `server`

`jetbrains/teamcity-server:${TC_VERSION}`.

- Waits for `db` healthy and `datadir-init` completed.
- `TEAMCITY_SERVER_MEM_OPTS` from `TC_MEM_OPTS`; `TZ` from `TC_TZ`.
- Publishes `${TC_PORT}:8111`.
- Healthcheck is a real HTTP probe of `/login.html`, not a port check: Tomcat binds 8111 within
  seconds and then returns 503 for minutes while TeamCity initialises. `curl` is present in the
  image, so no workaround is needed. `start_period` is 600s because the first boot builds the
  schema.

Maps all three volumes the image declares: `datadir`, `logs`, `temp`.

### `agent-1` … `agent-N`

`jetbrains/teamcity-agent:${TC_VERSION}`, one explicit service each rather than `deploy.replicas`.

Replicas would share one configuration volume, and that volume holds the authorization token the
server issues on first connection — agents would fight over an identity and lose it on restart.
Explicit services give each its own.

- `SERVER_URL: http://server:8111` — the in-network address, never the browser-facing URL. Using
  `http://localhost:8111` here is the most common cause of an agent that will not connect.
- `OWN_ADDRESS` set to the service name.
- `TZ` — without it the agent image forces `Europe/London`.
- `depends_on: server: service_started`, not `service_healthy`: the first boot can outlast any sane
  health timeout, and agents retry their own connection quite happily.

Maps all seven volumes the image declares, plus `/var/lib/docker` when Docker-in-Docker is on.

## Volumes

Everything is namespaced by `TC_STACK`. With the default name and three agents:

```
teamcity_datadir  teamcity_logs  teamcity_temp
teamcity_pgdata   teamcity_jdbc-cache
teamcity_agent-{1,2,3}-{conf,work,system,temp,logs,tools,plugins}
```

All eleven declared volumes are mapped deliberately. Docker creates an **anonymous** volume for any
declared `VOLUME` left unmapped: nothing fails, but agent tool and plugin caches are discarded on
every recreate, and unnamed volumes accumulate on the daemon. `./tc doctor` reports the
anonymous-volume count so a regression shows up.

## Inspecting

```sh
docker compose -f stack/docker-compose.yml --project-directory stack --env-file stack/.env config
```

Or just read the file — it is generated with the reasoning inline as comments.

> `docker compose config` prints every value from `.env`, including the database password. The REST
> access token lives in `stack/.secrets` and is not part of the compose file, so it is never
> included.

---

[← Docs index](../../README.md#documentation)
