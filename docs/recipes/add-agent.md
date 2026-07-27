# Add an agent

Scale the number of build agents up or down.

Use **Agents → Scale**, which re-renders the stack and applies it:

```sh
./tc          # Agents → Scale
```

Or set `TC_AGENTS` in `stack/.env` and `./tc up`.

## The three-agent limit

TeamCity's free Professional licence covers **three** agents, and the default stack runs exactly
three. Authorizing a fourth makes TeamCity **pause the entire build queue** until the count drops
back — it looks like a hang, not a licence error.

The console refuses more than three unless you opt in explicitly after being shown what happens.
Install a licence in TeamCity first if you need more.

## After scaling up

New agents connect but are not authorized. Run **Agents → Authorize**, or `./tc authorize`.

## After scaling down

The removed agents' volumes are kept, holding their authorization tokens and caches — scaling back
up reuses them, so those agents return already authorized. The console offers to delete them
instead, and **Agents → Prune volumes** finds them later.

---

[← Docs index](../../README.md#documentation)
