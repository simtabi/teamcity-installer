# Publishing

What is already in place to open-source this, what is left, and the legal position.

## Why it is worth publishing

There is a real gap. Searching for a way to run TeamCity in Docker turns up static `docker-compose.yml`
files and gists — `egregors/teamcity-docker-compose` and the repos derived from it, plus JetBrains'
own `teamcity-docker-samples`. Checked against the images they run:

| | Community repos | JetBrains sample | Here |
|---|---|---|---|
| Agent volumes mapped (image declares 7–8) | **0** | 0 | all 8 |
| `TZ` set (image forces `Europe/London`) | no | no | yes |
| `database.properties` seeded | no | no | yes |
| PostgreSQL data path | correct | **wrong** — `/var/lib/postgresql/${PG_VERSION}/docker` is not `PGDATA` | correct |
| Guided setup, validation | none | none | yes |
| Backups, restore guards, upgrade guards | none | none | yes |

The first three mean every agent leaks 7–8 anonymous volumes and re-downloads its tool cache on
each recreate, every build timestamp is an hour or more out, and the operator hand-configures the
database. None of it fails loudly.

## Legal position

Publishing is clean:

- **No redistribution.** The repo contains no JetBrains code. It references the official public
  images on Docker Hub, exactly as any `docker-compose.yml` does, and downloads the PostgreSQL JDBC
  driver (BSD-2-Clause) from Maven Central at runtime.
- **Trademark.** TeamCity is a registered trademark of JetBrains s.r.o. Use it descriptively —
  "a control console for TeamCity" — not as the leading element of the project's own name, and
  carry the not-affiliated notice already in the README.
- **The user's own licence.** Running TeamCity remains governed by JetBrains' terms. The console
  surfaces the free Professional limit (3 agents) rather than quietly helping anyone exceed it.

## Already in place

- `LICENSE` — MIT.
- Trademark and non-affiliation notice in the README.
- `.github/workflows/ci.yml` — lint and unit tests on every push; an opt-in and weekly end-to-end
  job that stands up a real stack, verifies it and tears it down.
- `./tc lint` (shellcheck) and `./tc test` (89 bats cases), both self-contained in the console image.
- `./tc verify` for the live surface.
- A docs tree covering guides, per-subsystem reference and recipes.
- `.gitignore` covering `stack/.env`, `stack/.secrets`, `backups/` and `logs/`.
- `Makefile` with `make check`, and `make perms` for checkouts that dropped file modes.

## The name

The project keeps **`simtabi/teamcity-installer`**. This is nominative use — the tool installs
TeamCity, and saying so is accurate — and it is what the whole ecosystem already does:
`teamcity-docker-compose`, `jetbrains-teamcity-docker`, `teamcity-docker-samples`. JetBrains has
not pursued any of them.

The mitigation is the notice, not the name: `LICENSE` and the README both state that the project
is unaffiliated, unendorsed, and redistributes no JetBrains software. Keep both if the name stays.

## Before the first push

1. **Check the history.** This project was developed without version control, so `git init` starts
   from a clean slate — there is no history to scrub. Confirm `stack/.env`, `stack/.secrets` and
   `logs/` are untracked before the first commit: they hold a database password, an access token,
   and an operational record.
2. **Decide about badges.** The README deliberately carries none, with the reason inline. If the
   repository goes public and CI runs on it, a Tests / Static analysis / License row becomes
   meaningful; a registry badge never will, since the tool is delivered as a repository rather
   than a package.
3. **Set the CI schedule owner.** The weekly end-to-end job pulls ~4 GB; confirm that is acceptable
   on the account it runs under.
4. **Say where it has been run.** [Platforms](platforms.md) states plainly that only macOS/arm64
   has been exercised. Publishing without that caveat would overstate the support.

## Verifying the claims

Every comparison above is reproducible:

```sh
# What the community repos map for agents
curl -s https://raw.githubusercontent.com/egregors/teamcity-docker-compose/master/docker-compose.yml \
  | grep -cE '/opt/buildagent|/data/teamcity_agent'      # 0

# What this stack maps
docker inspect teamcity-agent-1-1 \
  -f '{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}}{{"\n"}}{{end}}{{end}}' | wc -l   # 8

# What the agent image does when TZ is unset
docker run --rm --entrypoint sh jetbrains/teamcity-agent:2026.1.3 -c 'echo $TZ'   # Europe/London
```

`./tc verify` asserts the same properties on every run.

---

[← Docs index](../README.md#documentation)
