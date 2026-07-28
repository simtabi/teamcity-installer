# Agents

Scaling, listing, authorizing and pruning build agents.

## The licence limit

TeamCity's free Professional licence covers **three build agents**, and a fresh install ships with
all three authorized. That is why the wizard defaults to three.

Authorize a fourth and TeamCity does not degrade gracefully: it **pauses the entire build queue**
until the authorized count drops back within the licence. Nothing obviously fails — builds simply
stop starting — so it reads as a hang. The console refuses to render more than three agents unless
you opt in explicitly, and warns again before authorizing past the limit.

## Why authorization is manual

TeamCity documents an internal property — `teamcity.agentAutoAuthorize.authorizationToken` — that
is widely described as authorizing any agent presenting the same value. This project implemented
it, then removed it, because **it does not work on TeamCity 2026.1.3**:

- The server reads the property (it appears in the startup log), and agents presenting the matching
  token still register as **Unauthorized**.
- The agent image only writes `AGENT_TOKEN` into `buildAgent.properties` when that file has no
  token yet, so enabling it on an existing stack is accepted and silently ignored.
- Rewriting the token in the conf volume to force the issue makes things worse: the server treats a
  changed token as a **different agent**, orphaning the originals and creating duplicates named
  `<name>-1`.

Shipping a setting that quietly does nothing is worse than not having it, so authorization is an
explicit action that the console reduces to one command. If a future TeamCity makes the property
behave as documented, `console/lib/agents.sh` records where to reinstate it.

## Authorize manually

Agents connect automatically but are **not authorized**, so they take no builds. This is TeamCity's
default and easy to miss: the agents are visibly present and nothing runs.

**Agents → Authorize**, or `./tc authorize`.

The first run asks for a REST **access token**. This is not the super user token from first-run
setup — that one is for the browser and rotates on every restart. This one is created by you and
persists:

1. In TeamCity, click your name (top right) → **Access Tokens** → **Create access token**.
2. Give it permission to manage agents.
3. Paste it when prompted.

The token is verified against the live server before being stored in `stack/.secrets` (mode 600).
If it later stops working the console says so and asks again rather than failing obscurely.

Under the hood it lists `GET /app/rest/agents?locator=authorized:false` and `PUT`s to
`/app/rest/agents/id:<n>/authorizedInfo`, falling back to `/authorized` if the server rejects the
first path — which one is accepted has varied across TeamCity versions. If REST is unavailable for
any reason it prints the UI route instead:

```
http://localhost:8111/agents.html?tab=unauthorizedAgents
```

## List

**Agents → List**, or `./tc agents`.

```
ID  NAME              CONNECTED  AUTHORIZED  ENABLED
1   teamcity-agent-1  yes        yes         yes
2   teamcity-agent-2  yes        yes         yes
3   teamcity-agent-3  yes        yes         yes
```

Needs a stored token, since this is server-side state.

## Scale

**Agents → Scale** re-renders the compose file and applies it with `--remove-orphans`.

Scaling **down** removes the containers but keeps each agent's volumes, which hold its
authorization token and caches — scaling back up reuses them, so the agents return already
authorized rather than needing approval again. The console offers to delete them if you would
rather reclaim the space.

Scaling **up** adds agents that need authorizing.

## Prune

**Agents → Prune volumes** finds volumes named for this stack that the current compose file no
longer references — typically left by scaling down, or by renaming the stack.

It lists them with creation dates and requires you to type the stack name before deleting, because
those volumes may hold the only copy of an agent's identity.

## Why one service per agent

The compose file renders `agent-1`, `agent-2` … as separate services rather than using
`deploy.replicas`.

Replicas share a single configuration volume, and that volume holds the authorization token the
server issues on first connection. Sharing it means agents contend over one identity; losing it
means re-authorizing on every restart. Separate services give each agent its own.

---

[← Docs index](../../README.md#documentation)
