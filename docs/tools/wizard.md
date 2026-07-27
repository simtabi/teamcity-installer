# Wizard

The guided setup: what it asks, what each answer controls, and how it validates.

Run it from the menu (**Install**, or **Reconfigure** later) or with `./tc install`.

## Behaviour

- **Validated at the prompt.** Every answer is checked before the next question. A rejected value
  re-prompts with the specific reason, so you never carry a bad value forward.
- **Review before creating.** Nothing is written until you confirm a summary of every setting.
- **Idempotent.** Run against an existing stack it offers Reconfigure, Reset or Cancel rather than
  silently overwriting.
- **Defaults are prefilled.** Enter accepts the shown value; on reconfigure the defaults are your
  current settings.

## Questions

### Stack name

Default `teamcity`. Names the Compose project, so every container, volume and network is prefixed
with it. Must match `^[a-z][a-z0-9-]{1,30}$`.

Renaming later does not move data — the old volumes stay behind under the old prefix.

### TeamCity version

Default `2026.1.3`. The chooser is populated live from Docker Hub and lists **only tags that
publish an image for your architecture**, so you cannot accidentally pick one that would run under
emulation or not at all. Offline, it falls back to free text with the pinned default.

### HTTP port

Default `8111`. Must be 1024–65535 — TeamCity runs as uid 1000 in the container and cannot bind
privileged ports. Rejected if a container publishes it or a host process is listening; if the
default is taken, the next free port is suggested.

A port held by your own running stack is not treated as a conflict.

### Timezone

Defaults to your machine's zone, taken from `/etc/localtime` by the launcher. Applied to every
container. Without it the agent image forces `Europe/London` and every build timestamp is wrong.

### Database

**PostgreSQL** (default) creates a dedicated `postgres:17-alpine` container and seeds the JDBC
driver and `database.properties` into the data directory, so TeamCity's web setup skips the
database step.

**Bundled** uses TeamCity's HSQLDB. JetBrains support it for evaluation only; the wizard says so.

Credentials are generated. The password is 32 characters from a safe alphabet — it never contains
`$`, backticks, quotes or backslashes, which would break `.env` interpolation or the JDBC URL.

### Server JVM options

Default `-Xmx2g -XX:ReservedCodeCacheSize=640m`, matching the image default.

The **whole string** is validated, not just `-Xmx`. A validator that only understood `-Xmx` would
silently discard the code-cache setting the first time anyone edited the value. `-Xmx` must be at
least 1g, and you are warned above 70% of the Docker VM's memory.

### Agent count

Default **3** — the full entitlement of TeamCity's free Professional licence, which ships with
three authorized agents.

Above three the licence is exceeded and TeamCity **pauses the entire build queue** until you drop
back. That reads as a hang rather than a licence problem, so the wizard refuses four or more unless
you explicitly opt in after being told what will happen. You are also warned past half your CPU
count.

### Agent image

**Full** (default) ships git, git-lfs, .NET, Perforce and the Docker CLI. **Minimal** is a JRE and
the agent only; you install build tools yourself.

### Docker access for agents

| Option | Effect |
|---|---|
| **No** (default) | Agents cannot run Docker builds. Simplest and safest. |
| **Docker-in-Docker** | An isolated daemon inside each agent. Requires `privileged: true`, which can escape to the Docker VM. Forces the full image and gives each agent its own `/var/lib/docker` volume so layers survive restarts. |
| **Host socket** | Mounts the host daemon's socket. Much lighter than DinD, but any build gets root-equivalent control of the VM. Only for builds you trust. |

Each caveat is stated inline at the prompt, not buried here.

## Afterwards

The wizard writes `stack/.env`, renders `stack/docker-compose.yml`, offers to start the stack, and
then tells you the two remaining steps: finish TeamCity's own setup in the browser, and authorize
the agents.

---

[← Docs index](../../README.md#documentation)
