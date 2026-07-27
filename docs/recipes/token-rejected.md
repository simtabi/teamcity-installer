# Fix a rejected super user token

TeamCity's first-run page reports:

```
Incorrect token was entered. Authentication failed
```

## Almost always: the token is stale

A **new super user token is issued every time the server starts**, and the old one dies with the
previous run. The server log accumulates one line per start, so a number you were given earlier —
or copied from further up the log — will be rejected. The message says nothing about this.

```sh
./tc token
```

That reads the newest token *and* replays it against the server before showing it:

```
2000000000000000002
ok     Verified — the server accepts this token right now.
```

If it reports the server rejected it, the server has restarted since the token was written. Wait a
few seconds for the new one to be logged and run it again.

Enter it with the **username left blank**.

## Other causes

**You restarted the stack between reading and pasting.** Anything that recreates the server
container — `./tc restart`, `./tc up` after a config change, an upgrade — issues a new token. Read
it after the restart, not before.

**The server has finished setup.** Once an administrator account exists the maintenance page is
gone and this token is no longer used for it; sign in normally instead. `./tc doctor` shows which
state the server is in.

**You are looking at the wrong stack.** With more than one stack, `./tc token` reads the log of the
stack named in `stack/.env`. Check `TC_STACK` matches the port you have open.

## Why the console can check this

The maintenance page posts `{ token }` to `/mnt/do/authenticate` behind a CSRF check and answers
`OK` or the rejection message. The console replays exactly that, so it can tell you whether the
token works rather than printing a number and leaving you to find out. Authenticating does not
consume the token — it stays valid until the next restart.

---

[← Docs index](../../README.md#documentation)
