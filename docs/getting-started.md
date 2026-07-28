# Getting started

From an empty checkout to a TeamCity server with authorized agents ready to build.

## 1. Run the console

```sh
./tc
```

The first run builds the console image, then shows the menu. Before installing, **Preflight** is
worth a look — it checks memory, disk, port availability and image architecture, and tells you how
to fix anything it does not like.

## 2. Guided setup

Choose **Install**. The wizard asks for a stack name, TeamCity version, HTTP port, timezone,
database, JVM options and agent count, showing a summary before it creates anything. Every answer
is validated as you type: a privileged port, a short password or a version with no image for your
architecture is rejected with the reason, not a generic error.

Accepting the defaults gives you TeamCity 2026.1.3 on port 8111, PostgreSQL 17, and three agents —
three because that is what TeamCity's free Professional licence covers.

Say yes to starting the stack. The first boot pulls around 8 GiB of images and then builds the
database schema, which takes a few minutes. The console waits and tells you when HTTP answers.

## 3. Finish TeamCity's own setup

Open `http://localhost:8111`.

### The super user token

The first page is **TeamCity Maintenance**, asking for a *Super User token* before it will show
you the licence agreement:

> The Super User token can be found in the `<TeamCity Server home>/logs/teamcity-server.log`

In a container that path is inside a Docker volume, so that instruction is a dead end. Get it from
the console instead:

```sh
./tc token
```

Paste it in and **leave the username blank**.

`./tc token` verifies the token against the server before showing it, so you know it is live:

```
2000000000000000002
ok     Verified — the server accepts this token right now.
```

> **A new token is issued on every server start.** The log accumulates one per start, and only the
> newest works — an older one is rejected with *"Incorrect token was entered. Authentication
> failed"*, which does not hint that staleness is the cause. If you see that, run `./tc token`
> again rather than reusing a number from earlier.
>
> It grants full administrative access; treat it like a root password. `./tc up` prints and
> verifies it automatically when it finds the stack in this state.

### Then

Because the console has already written `database.properties` and installed the PostgreSQL JDBC
driver into the data directory, TeamCity **skips the database step**. You go straight to:

1. **Review and accept the licence agreement.**
2. **Create the administrator account.**

That is all. TeamCity is now usable.

## 4. Authorize the agents

Your three agents have connected but are not yet authorized, so they will not take builds. This is
TeamCity's default and is easy to miss — the agents look present but nothing runs.

One command, and no token to create — the console authenticates with the super user token it
already reads from the log:

```sh
./tc authorize
```

```
ok     authorized teamcity-agent-1
ok     authorized teamcity-agent-2
ok     authorized teamcity-agent-3
ok     3 agent(s) authorized.
```

Confirm with **Agents → List**, or `./tc agents`.

## The two tokens

Two tokens appear in this flow and they are unrelated. Mixing them up is the most likely way to
get stuck.

| | Super user token | Access token |
|---|---|---|
| **What for** | unlocking TeamCity's first-run maintenance page | letting the console authorize agents over REST |
| **Where from** | `./tc token` (read out of the server log) | TeamCity UI → your profile → Access Tokens |
| **Lifetime** | regenerated on every server restart | until you revoke it |
| **Stored** | never — read fresh each time | `stack/.secrets`, mode 600 |
| **Used by** | you, in the browser | the console |

## 5. Day to day

```sh
./tc            # menu
./tc up         # start
./tc down       # stop, keeping data
./tc status     # health and ports; non-zero exit when not fully up
./tc logs server
./tc backup     # cold backup into backups/
./tc doctor     # diagnostics
```

Stopping is safe — `down` stops containers and leaves every volume intact. Only `reset` destroys
data, and it requires typing the stack name to confirm.

## Next

- [Users](users.md) — adding more users, and getting back in if you are locked out
- [Data safety](data-safety.md) — which commands keep your data and which destroy it

- [Configuration](configuration.md) — change the port, memory, agent count or version
- [Backup](tools/backup.md) — pick the right backup tier before you need one
- [Fix an agent that will not connect](recipes/fix-agent-cannot-connect.md)

---

[← Docs index](../README.md#documentation)
