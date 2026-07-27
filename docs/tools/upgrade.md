# Upgrade

Moving the stack to a different TeamCity version, and the two things that make it awkward.

```sh
./tc upgrade
```

Or **Upgrade** from the menu.

## What it does

1. Lists versions from Docker Hub that publish an image for your architecture.
2. **Refuses downgrades.** TeamCity will not start against a data directory an newer server has
   already upgraded, and the error it gives does not obviously mean "you went backwards". Cheaper
   to refuse up front, naming the backup route if you really need to go back.
3. **Takes a backup first, with no opt-out.** The data directory is upgraded in place; without a
   backup there is no way back.
4. Pulls the new images. A failed pull reverts `TC_VERSION` and re-renders, leaving you where you
   started.
5. Recreates the containers.
6. Watches the log for the maintenance token — see below.

## The maintenance token

On a version change TeamCity serves a maintenance page that will not proceed until you supply a
one-time token, which it prints **to the server log and nowhere else**.

Left to find it yourself, you see a page asking for a token with no indication of where it comes
from, and it looks like the upgrade has hung. The console tails the log, extracts the token and
prints it:

```
warn   TeamCity needs you to confirm the data directory upgrade.
         1. Open  http://localhost:8111
         2. Enter this token:

              4f8a1c9e2b7d

         3. Confirm the upgrade and wait for it to finish.
```

If the version change needed no confirmation, it says so and finishes.

## Rolling back

There is no in-place downgrade. Restore the backup taken immediately before the upgrade:

```sh
$EDITOR stack/.env        # set TC_VERSION back
./tc restore              # pick the pre-upgrade archive
```

The restore guards will confirm the archive matches the version you have set — see
[backup](backup.md).

## Rehearsing an upgrade

Because every stack is namespaced by `TC_STACK`, you can rehearse an upgrade against a throwaway
copy instead of your real one. Copy the project to a scratch directory, give it a different stack
name and port, pin the version you are on today, and upgrade that:

```sh
cp -R . /tmp/tc-rehearsal && cd /tmp/tc-rehearsal
rm -f stack/docker-compose.yml
$EDITOR stack/.env      # TC_STACK='rehearsal'  TC_PORT='8112'  TC_AGENTS='0'  TC_DB='hsqldb'
./tc up
./tc upgrade
```

`TC_AGENTS='0'` and `TC_DB='hsqldb'` keep it to a single container, so the only cost is pulling the
one server image. Tear it down with `./tc reset` when you are done — it shares no volumes, network
or containers with your real stack.

## Upgrading PostgreSQL

`TC_PG_VERSION` is not touched by this command, and changing it needs a different route: a raw
PostgreSQL data directory does not load across major versions. Take a **logical** or **native**
backup, change the version, reset, restore.

---

[← Docs index](../../README.md#documentation)
