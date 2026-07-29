# Users and the super user token

How the first administrator is created, how to add more users, and how to get back in when nobody
can log in.

## The super user token is not a user

It is worth being precise, because the two are easy to conflate:

| | Super user token | Administrator account |
|---|---|---|
| What it is | a one-time password TeamCity prints to its log | a real user, with a name and a password |
| Username | **none — leave the field blank** | the one you choose |
| Lifetime | until the next server restart | until you delete it |
| Stored | nowhere; read fresh from the log each time | in TeamCity's database |
| What it is for | unlocking setup, and rescuing a locked-out server | day-to-day use |

The token does not create anything by itself. It gets you *past the gate* so you can create the
first real account.

## Creating the first administrator

The console does this for you. When the server comes up with no accounts, `./tc up` creates one; you
can also run it directly:

```sh
./tc admin
```

```
ok     Administrator 'admin' created with full system rights.

         username:  admin
         password:  fAdjvuvpav1CRmTFkgVxQhxdGU1pK9nF
```

It authenticates with the super user token, creates the account over REST, and grants it
`SYSTEM_ADMIN` — a new account has no privileges otherwise, and signing in to find you can do
nothing is a poor welcome.

The password is **generated and shown once**, not written to disk. A second copy in `stack/.env`
would go stale the moment you changed it in the UI. Set `TC_ADMIN_USER` and `TC_ADMIN_PASSWORD` in
`stack/.env` if you need known values — for CI, say — and those are used instead.


### If you lose it

```sh
./tc admin reset            # or: ./tc admin reset <username>
```

Shown-once means exactly that: miss the line and you are locked out of an account that exists and
works. This resets it, authenticating with the super user token — which is why it works when nobody
knows any password: TeamCity prints that token to its log on every start, and the console reads it.

The new password is **verified before it is shown**. A 200 on the request means TeamCity accepted
it, not that anyone can sign in with the result, and being unable to sign in is the whole problem —
so the console authenticates with the new credential as that user, with no fallback to any other
identity, and says whether it worked.

Set `TC_ADMIN_PASSWORD` first if you want a specific value rather than a generated one. It is shown
once again, for the same reason.

This runs only when there are **zero** users. It is a bootstrap, not user management: once anybody
exists, further accounts belong in TeamCity's own UI where roles and groups live.

## Doing it by hand instead

On a fresh stack TeamCity serves a maintenance page before anything else.

**1. Get the token.**

```sh
./tc token
```

It reads the token from inside the server's log volume — where TeamCity's own instruction
("look in `<TeamCity Server home>/logs/teamcity-server.log`") dead-ends in a container — and
verifies it against the server before showing it:

```
2000000000000000002
ok     Verified — the server accepts this token right now.
```

**2. Enter it at `http://localhost:8111`, leaving the username blank.**

**3. Accept the licence agreement.**

**4. Create the administrator account** — username, password, email. This is the account you will
actually use.

That account is stored in the database, so it survives restarts, upgrades and `./tc down`.

> A new token is issued on **every server start**. If you restart between reading and pasting, the
> one you have is dead — run `./tc token` again. See
> [fix a rejected token](recipes/token-rejected.md).

## If the server started before you created an account

TeamCity can finish starting — `/login.html` answers 200, everything looks healthy — with **no user
accounts at all**. Nobody can sign in, and nothing about the page says why.

The console names that state rather than reporting the server as ready:

```
warn   Up at http://localhost:8111, but no user account exists yet — run  ./tc token
```

`./tc verify` fails the check, and `./tc doctor` says the same. To get in:

```sh
./tc token
```

Sign in at `/login.html` with a **blank username** and the token as the password, then
**Administration → Users → Create user account**.

## Adding more users

Once an administrator exists, users are managed inside TeamCity, not by this console:

**Administration → Users → Create user account**, or let people self-register if you enable it
under **Administration → Authentication**.

Roles are assigned per user or per group under **Administration → Roles**. TeamCity's own
[documentation on user management](https://www.jetbrains.com/help/teamcity/creating-and-managing-users.html)
covers the details; nothing here changes how it works.

The console deliberately does not wrap this. Creating users is a routine administrative task with a
perfectly good UI, and a thin shell wrapper over it would add a second place for permissions to
drift out of sync.

## Locked out

The super user token is also the recovery path — it works at any time, not only during setup:

```sh
./tc token
```

Sign in at `http://localhost:8111/login.html` with a **blank username** and the token as the
password. You land with full administrative rights and can reset a password or create a new
administrator.

Use a private browser window: signing in as super user in your normal session replaces whatever
you were signed in as.

If the token is rejected, the server has restarted since it was logged — read it again.

## The other token

The console also stores a **REST access token**, which is unrelated: you create it in the TeamCity
UI and it lets the console authorize agents on your behalf. It lives in `stack/.secrets`, mode 600,
deliberately outside `stack/.env` so it cannot leak through `docker compose config`.

With agent auto-authorization enabled — the default — you may never need one. See
[agents](tools/agents.md).

---

[← Docs index](../README.md#documentation)
