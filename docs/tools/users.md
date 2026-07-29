# Users

Seeing who can sign in, and giving them a password when nobody can.

```sh
./tc users                  # every account
./tc users show <username>  # one account in detail
./tc users passwd <user>    # set a password
```

TeamCity's own UI is the right place to manage users — roles, groups, notification rules and
permissions all live there. This exists for the one case the UI cannot help with: when nobody can
sign in to reach it.

## Listing

```
ID  USERNAME  NAME           EMAIL  ADMIN  LAST SIGN-IN
3   admin     Administrator  -      yes    2026-07-29 09:20

ok  1 account(s), 1 with system administrator rights.
```

The `ADMIN` column is `SYSTEM_ADMIN` at global scope — the accounts that can rescue the others. If
none of them do, the listing says so and points at the super user token, because that is the only
way back in from a server nobody can administer.

The fields are requested explicitly: TeamCity's default user response carries username, name, id
and a href, with no email, no roles and no last login. A table built from the default would show
three empty columns and look like missing data rather than an unasked question.

## Setting a password

The value is taken from the first of these that applies:

| Source | When |
|---|---|
| standard input | something is piping one in |
| a prompt, entered twice | there is a terminal to prompt on |
| generated | neither — shown once, then not stored |

```sh
printf 'correct horse battery staple' | ./tc users passwd alice
```

Standard input rather than an environment variable, for two reasons. The launcher passes a fixed set
of variables into the container, so a `TC_NEW_PASSWORD` set on the host would never arrive — the
scripted path would look supported and quietly generate a password instead. And a secret passed with
`docker run -e` is visible in `docker inspect` for the life of the container; a pipe is not.

A password you typed is not echoed back. Only a generated one is printed, because that is the only
one you have no other copy of.

## Why it works when nobody knows a password

The console authenticates over REST with the **super user token**, which TeamCity writes to its log
on every start. That is what makes this a recovery rather than a convenience: it needs no existing
credential, only access to the machine running the stack.

Which is also why nothing here stores a password. A copy on disk goes stale the moment someone
changes it in the UI, and it would add a plaintext credential at rest without adding any capability
— resetting is already always available.

## It verifies before it reports

A 200 on the request means TeamCity accepted it, not that anyone can sign in with the result — and
being unable to sign in is the entire reason the command exists. So the new credential is used to
authenticate as that user, with **no fallback** to any other identity.

That distinction matters: every other REST call in this console falls back through the stored access
token and then the super user token. Used for this check it would answer "authenticated" for a
password that does not work at all.

## Related

- [users and tokens](../users.md) — the concepts: super user token against a real account
- [`./tc admin`](../users.md#the-first-administrator) — creating the first account on a fresh server

---

[← Docs index](../../README.md#documentation)
