# Configuration

Every setting the stack has, where it lives, and what changing it does.

Settings live in `stack/.env`. The wizard writes it; editing it by hand is supported.

**A missing `stack/.env` is created for you.** Any command finds the file absent, copies
`stack/.env.example`, and fills in a generated database password — so a fresh clone works without a
separate setup step. An existing file is never overwritten.

**Values are validated before any command acts on them.** This used to happen only when the compose
file was rendered, so a command that did not render — `status`, `logs`, `token`, `doctor` — ran
against a broken configuration and failed somewhere less obvious. Now the failure names the setting:

```
error  TC_PORT is '80'; it must be a number between 1024 and 65535.
error  stack/.env has values that would make this fail later.
```

`install`, `reset`, `lint`, `test`, `preflight` and `journal` are exempt, since gating the commands
that repair a configuration on that configuration being valid would leave no way out. Values are
single-quoted, and every one is re-validated when the compose file is rendered — a bad edit is
rejected with a reason rather than producing a stack that fails later.

> Keep the quotes when editing. `TC_MEM_OPTS` contains spaces, and unquoted it parses as two
> separate things. See [architecture](architecture.md) for why the file is parsed rather than
> sourced.

## Settings

| Key | Default | What it does |
|---|---|---|
| `TC_STACK` | `teamcity` | Names the Compose project, and therefore every container, volume and network. Changing it orphans the old stack's volumes. |
| `TC_VERSION` | `2026.1.3` | Image tag for the server and agents. Change it with **Upgrade**, not by hand — see below. |
| `TC_PORT` | `8111` | Host port for the web UI. Must be ≥ 1024 and free. |
| `TC_TZ` | host zone | Timezone for every container. Without it the agent image forces `Europe/London` and build timestamps are wrong. |
| `TC_DB` | `postgres` | `postgres` or `hsqldb`. HSQLDB is TeamCity's bundled database and JetBrains support it for evaluation only. |
| `TC_PG_VERSION` | `17` | PostgreSQL major. Changing it invalidates cold backups — see [backup](tools/backup.md). |
| `TC_PG_DB` | `teamcity` | Database name. |
| `TC_PG_USER` | `teamcity` | Database user. |
| `TC_PG_PASSWORD` | generated | Cannot contain `$`, backtick, quotes or backslash: those break `.env` interpolation and the JDBC URL. Minimum 16 characters. |
| `TC_JDBC_VERSION` | `42.7.13` | PostgreSQL JDBC driver version, fetched from Maven Central and checksum-verified. |
| `TC_MEM_OPTS` | `-Xmx2g -XX:ReservedCodeCacheSize=640m` | Server JVM options. The whole string is validated, not just `-Xmx`. Minimum 1g. |
| `TC_AGENTS` | `3` | Number of agents. Above 3 the free licence is exceeded and TeamCity pauses the build queue. |
| `TC_AGENT_IMAGE` | `full` | `full` (git, .NET, Perforce, Docker CLI) or `minimal` (JRE only). |
| `TC_AGENT_DOCKER` | `none` | `none`, `dind` or `socket`. Either Docker mode forces the full agent image — the minimal one contains no `docker` binary. See [enable Docker builds](recipes/enable-docker-in-docker.md). |
| `TC_AGENT_AUTO_AUTHORIZE` | `1` | Agents authorize themselves on first connect instead of waiting for approval. See [agents](tools/agents.md). |
| `TC_AGENT_AUTH_TOKEN` | generated | The shared secret behind the above. Generated once per stack and reused, so agents already holding it stay authorized. Empty disables the feature. |
| `TC_ADMIN_USER` | `admin` | Username for the first administrator, created automatically when the server has no accounts. |
| `TC_ADMIN_PASSWORD` | empty | Leave empty to have one generated and shown once. Set it only when you need a known value. |
| `TC_BACKUP_KEEP` | `5` | Archives to keep; older ones are pruned after each successful backup. |
| `TC_LOG_LEVEL` | `INFO` | `DEBUG`, `INFO`, `WARN`, `ERROR` or `OFF`. See [logging](tools/logging.md). |

## Applying a change

Any lifecycle command re-renders the compose file first, so:

```sh
$EDITOR stack/.env
./tc restart
```

If a value fails validation, rendering stops and nothing is applied:

```
error  -Xmx is -Xmx256m. TeamCity needs at least 1g and will fail to start below it.
error  stack/.env failed validation; refusing to render a broken stack.
```

## Settings that need more than a restart

**`TC_VERSION`** — use **Upgrade** instead. It refuses downgrades, forces a backup first, and
surfaces the one-time token TeamCity prints when it needs confirmation to upgrade the data
directory. Editing the version by hand skips all three.

**`TC_STACK`** — renaming does not move anything. The old volumes stay behind under the old prefix,
and the new stack starts empty. Back up first, rename, restore.

**`TC_DB`** — switching between PostgreSQL and HSQLDB does not migrate data. Take a **native**
backup, which is the only tier that moves between database backends, then switch and restore.

**`TC_PG_VERSION`** — a raw PostgreSQL data directory does not load across major versions. Take a
logical or native backup, change the version, reset, restore.

## The access token

The TeamCity REST access token is kept in `stack/.secrets`, not `.env`, because everything in
`.env` appears in `docker compose config` output and in diagnostics bundles. Both files are mode
600 and gitignored.

The console prompts for a token when it first needs one, verifies it against the live server, and
re-prompts if it later stops working.

---

[← Docs index](../README.md#documentation)
