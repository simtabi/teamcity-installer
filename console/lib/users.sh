#!/usr/bin/env bash
#
# users.sh — see who can sign in, and give them a password when they cannot.
#
# TeamCity's own UI is the right place to manage users: roles, groups,
# notification rules and permissions all live there and none of them belong in a
# shell script. This module exists for the one thing the UI cannot help with —
# when nobody can sign in to reach it.
#
# That situation is not exotic. `./tc admin` generates a password, prints it once
# and deliberately never writes it down, because a second copy on disk goes stale
# the moment it changes in the UI. Miss that line and the account exists, works,
# holds every permission, and is unreachable.
#
# The way back is the super user token: TeamCity writes it to its log on every
# start, the console already reads it, and it authenticates over REST with full
# administrative rights. So a password can always be set without knowing any
# password — which is why nothing here needs to store one.
#
#   ./tc users                see every account
#   ./tc users show <name>    one account in detail
#   ./tc users passwd <name>  set a password, and prove it works

# The fields worth a column. Requested explicitly because the default listing
# returns username, name, id and href only — no email, no roles, no last login —
# and a user table without "can this account rescue the others" is not much use.
USERS_FIELDS='count,user(id,username,name,email,lastLogin,roles(role(roleId,scope)),groups(group(key,name)))'

# TeamCity returns timestamps as 20260729T092018-0400, which is a correct ISO
# basic-format string and unreadable in a column. Reformatted here rather than
# left raw: this is the field people scan to answer "is this account still in
# use", and they should not have to parse it character by character.
users::_when() {
    local raw=$1
    [[ -n $raw && $raw != null ]] || { printf 'never'; return; }
    if [[ $raw =~ ^([0-9]{4})([0-9]{2})([0-9]{2})T([0-9]{2})([0-9]{2}) ]]; then
        printf '%s-%s-%s %s:%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" \
                                "${BASH_REMATCH[4]}" "${BASH_REMATCH[5]}"
    else
        printf '%s' "$raw"
    fi
}

users::_fetch_all() {
    agents::_rest GET "/app/rest/users?fields=$USERS_FIELDS"
}

users::_fetch_one() {
    agents::_rest GET "/app/rest/users/username:$1?fields=$(printf '%s' "$USERS_FIELDS" | sed 's/^count,user(//; s/)$//')"
}

users::menu() {
    ui::scope users
    while true; do
        local choice
        choice=$(ui::menu 'Users' \
            'List|every account, and who can administer' \
            'Show|one account in detail: roles, groups, last sign-in' \
            'Set password|works even when nobody knows one' \
            'Back|') || return 0

        case $choice in
            List)           users::list; ui::pause 'List' ;;
            Show)           users::_pick_then show; ui::pause 'Show' ;;
            'Set password') users::_pick_then passwd; ui::pause 'Set password' ;;
            Back)           return 0 ;;
        esac
    done
}

# Choosing from the real accounts rather than asking someone to type a username
# they may have come here to look up.
users::_pick_then() {
    local action=$1 json names pick

    json=$(users::_fetch_all 2>/dev/null) || {
        ui::err 'Could not read the user list.'
        return 1
    }

    local -a names=()
    mapfile -t names < <(printf '%s' "$json" | jq -r '.user[].username' | LC_ALL=C sort)
    if (( ${#names[@]} == 0 )); then
        ui::warn 'No accounts exist yet. Create the first with:  ./tc admin'
        return 0
    fi

    pick=$(ui::choose 'Which account?' "${names[@]}") || return 0
    "users::$action" "$pick"
}

# --- list ---------------------------------------------------------------------

users::list() {
    ui::scope users
    stack::installed || { ui::err 'No stack configured.'; return 1; }

    if [[ $(stack::server_state) != ready ]]; then
        ui::err "TeamCity is not ready: $(stack::not_ready_reason)."
        ui::note 'Start it with  ./tc up  and try again.'
        return 1
    fi

    local json
    json=$(users::_fetch_all) || {
        ui::err 'Could not read the user list.'
        ui::note 'The server is up but did not answer on REST. Try  ./tc doctor'
        return 1
    }

    ui::head 'Users'

    local count; count=$(printf '%s' "$json" | jq -r '.count // 0')
    if [[ $count == 0 ]]; then
        # Reachable, and the most confusing state TeamCity has: everything
        # healthy, nobody able to sign in.
        ui::warn 'No accounts exist on this server.'
        ui::note 'Create the first one with:  ./tc admin'
        return 0
    fi

    {
        printf 'ID,USERNAME,NAME,EMAIL,ADMIN,LAST SIGN-IN\n'
        printf '%s' "$json" | jq -r '
            .user[]
            | [ (.id|tostring),
                .username,
                (.name  // "-"),
                (.email // "-"),
                (if [.roles.role[]? | select(.roleId == "SYSTEM_ADMIN" and .scope == "g")] | length > 0
                 then "yes" else "no" end),
                (.lastLogin // "never")
              ]
            | @csv' | tr -d '"' \
        | while IFS=, read -r id name_u name email admin seen; do
              printf '%s,%s,%s,%s,%s,%s\n' "$id" "$name_u" "$name" "$email" "$admin" "$(users::_when "$seen")"
          done
    } | column -t -s, >&2

    ui::blank
    local admins
    admins=$(printf '%s' "$json" | jq -r '
        [ .user[] | select([.roles.role[]? | select(.roleId == "SYSTEM_ADMIN" and .scope == "g")] | length > 0) ]
        | length')

    ui::ok "$count account(s), $admins with system administrator rights."

    # The state that ends in a support request: accounts exist, none of them can
    # administer anything, and the UI offers no way to fix it from inside.
    if (( admins == 0 )); then
        ui::blank
        ui::warn 'No account holds SYSTEM_ADMIN, so nobody can administer this server.'
        ui::note 'Sign in with the super user token (./tc token, blank username) and grant it.'
    fi
}

# --- show ---------------------------------------------------------------------

users::show() {
    ui::scope users
    local user=${1:-}
    [[ -n $user ]] || { ui::err 'Which account? Usage: ./tc users show <username>'; return 2; }

    if [[ $(stack::server_state) != ready ]]; then
        ui::err "TeamCity is not ready: $(stack::not_ready_reason)."
        return 1
    fi

    local json
    json=$(users::_fetch_one "$user") || {
        ui::err "No account '$user' on this server."
        ui::note 'List them with:  ./tc users'
        return 1
    }

    ui::head "User — $user"
    ui::note "  id            $(printf '%s' "$json" | jq -r '.id')"
    ui::note "  username      $(printf '%s' "$json" | jq -r '.username')"
    ui::note "  name          $(printf '%s' "$json" | jq -r '.name // "-"')"
    ui::note "  email         $(printf '%s' "$json" | jq -r '.email // "-"')"
    ui::note "  last sign-in  $(users::_when "$(printf '%s' "$json" | jq -r '.lastLogin // ""')")"

    local roles groups
    roles=$(printf '%s' "$json" | jq -r '[.roles.role[]? | "\(.roleId) (\(.scope))"] | join(", ")')
    groups=$(printf '%s' "$json" | jq -r '[.groups.group[]? | .name] | join(", ")')
    ui::note "  roles         ${roles:--}"
    ui::note "  groups        ${groups:--}"
}

# --- passwd -------------------------------------------------------------------

# Sets a password for any account, and proves the result before reporting it.
#
# The value comes from whichever of these applies, in order: standard input when
# something is piping one in, a prompt when there is a terminal to prompt on, and
# otherwise a generated one.
#
# Standard input rather than an environment variable, for two reasons. The
# launcher passes a fixed set of variables into the container, so a TC_NEW_PASSWORD
# set on the host would simply never arrive — the scripted path would look
# supported and quietly generate a password instead. And a secret passed with
# `docker run -e` is visible in `docker inspect` for the life of the container,
# which a pipe is not.
#
#     printf 'correct horse battery staple' | ./tc users passwd alice
#
# Generated is the last resort rather than the default: a password you chose is
# one you can remember, and a generated one has to be captured from this output
# or set again.
users::passwd() {
    ui::scope users
    stack::installed || { ui::err 'No stack configured.'; return 1; }

    local user=${1:-${TC_ADMIN_USER:-admin}}

    if [[ $(stack::server_state) != ready ]]; then
        ui::err "TeamCity is not ready: $(stack::not_ready_reason)."
        ui::note 'Start it with  ./tc up  and try again.'
        return 1
    fi

    users::_fetch_one "$user" >/dev/null 2>&1 || {
        ui::err "No account '$user' on this server."
        ui::note 'List them with:  ./tc users'
        return 1
    }

    ui::head "Set password — $user"

    local pass='' generated=0
    if [[ ! -t 0 ]]; then
        # An empty or closed stdin returns immediately and leaves this blank, so
        # a piped-in nothing falls through to generation rather than hanging.
        IFS= read -r pass || true
        [[ -n $pass ]] && ui::note 'Using the password supplied on standard input.'
    fi

    if [[ -z $pass ]] && ! ui::plain; then
        local again
        pass=$(ui::secret 'New password') || return 0
        again=$(ui::secret 'Again') || return 0
        if [[ $pass != "$again" ]]; then
            ui::err 'The two entries do not match; nothing was changed.'
            return 1
        fi
    fi

    if [[ -z $pass ]]; then
        pass=$(validate::gen_password)
        generated=1
        ui::note 'Generated a password for this account.'
    fi

    if ! users::_set_password "$user" "$pass"; then
        ui::err "TeamCity would not accept that password for '$user'."
        ui::note "Its own password policy applies here exactly as it does in the browser."
        return 1
    fi

    # Proving it, not reporting it. A 200 says the request was accepted; it does
    # not say anyone can sign in with the result, and being unable to sign in is
    # the entire reason this command exists.
    if users::_verify "$user" "$pass"; then
        ui::blank
        ui::ok "Password set and verified — '$user' can sign in with it now."
    else
        ui::blank
        ui::warn 'The password was accepted but signing in with it did not work.'
        ui::note 'The account may be disabled or locked. Check it in TeamCity.'
    fi

    # Echoed only when the user did not choose it. Printing back something they
    # just typed is noise, and it puts a password on a screen for no reason.
    if (( generated )); then
        ui::blank
        ui::note '  username:'
        if ui::plain; then
            printf '        %s\n' "$user" >&2
            printf '  password:\n        %s\n' "$pass" >&2
        else
            gum style --foreground "$UI_ACCENT" --bold --padding '0 8' "$user" >&2
            ui::note '  password:'
            gum style --foreground "$UI_ACCENT" --bold --padding '0 8' "$pass" >&2
        fi
        ui::blank
        ui::note 'Shown once and not stored anywhere.'
    fi

    ui::note "Sign in at $(conf::url)/login.html"
    # The loop closed at the moment the risk is created, rather than in a document
    # nobody reads until they are already locked out.
    ui::note "Lost it? Run  ./tc users passwd $user  again — no password needed."
}

users::_set_password() {
    agents::_rest PUT "/app/rest/users/username:$1/password" "$2" 'text/plain' 'text/plain' >/dev/null 2>&1
}

# Deliberately not agents::_rest: that falls back through the stored access token
# and then the super user token, so it would answer "authenticated" for a
# password that does not work at all.
users::_verify() {
    agents::_rest_as "$1" "$2" GET "/app/rest/users/username:$1" >/dev/null 2>&1
}
