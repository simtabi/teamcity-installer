#!/usr/bin/env bash
#
# admin.sh — bootstrap the first administrator account.
#
# A freshly started TeamCity has a licence accepted and no users at all. The
# server answers 200, every container is healthy, and nobody can sign in: the
# last hurdle of a first run, and the one that looks least like a problem.
#
# Creating that account needs no browser. The super user token — which the
# console already reads out of the server log — authenticates over REST, so the
# account can be created and granted SYSTEM_ADMIN in two calls.
#
# This runs only when there are *zero* users. It is a bootstrap, not user
# management: once anybody exists, further accounts belong in TeamCity's own UI,
# where roles and groups live.
#
# The one exception is a password reset, because bootstrapping creates a problem
# it has to be able to undo. The generated password is shown once and never
# written down — deliberately, since a second copy on disk goes stale the moment
# it is changed in the UI — so anyone who misses that line is locked out of an
# account that exists and works. The recovery was documented and never built:
# "use the super user token and reset it in the UI" is a browser, six clicks and
# a page nobody has seen before. The same two REST calls that created the account
# can reset it.

# Does the server have any accounts at all?
admin::exists() {
    local n; n=$(stack::user_count 2>/dev/null) || return 2
    [[ -n $n ]] || return 2
    (( n > 0 ))
}

# admin::_set_password <username> <password>
#
# Authenticated by the super user token, which is why this works when nobody
# knows any password: TeamCity prints that token to its log on every start, and
# the console already reads it.
admin::_set_password() {
    local user=$1 pass=$2
    agents::_rest PUT "/app/rest/users/username:$user/password" "$pass" 'text/plain' 'text/plain' >/dev/null 2>&1
}

# admin::create <username> <password>
admin::_create() {
    local user=$1 pass=$2

    local body
    body=$(jq -n --arg u "$user" --arg p "$pass" \
        '{username: $u, password: $p, name: "Administrator"}')

    agents::_rest POST /app/rest/users "$body" 'application/json' 'application/json' >/dev/null 2>&1 || return 1

    # A new account has no privileges; without this it can sign in and do
    # nothing, which is a confusing thing to hand someone.
    agents::_rest PUT "/app/rest/users/username:$user/roles/SYSTEM_ADMIN/g" >/dev/null 2>&1 || return 2
}

# Creates the first administrator, or explains why it did not.
admin::bootstrap() {
    ui::scope admin
    stack::installed || { ui::err 'No stack configured.'; return 1; }

    ui::head 'Administrator account'

    case $(stack::server_state) in
        starting) ui::err 'TeamCity is not answering yet.'
                  ui::note 'Wait for it to finish starting, then try again.'
                  return 1 ;;
        setup)    ui::err "TeamCity is not ready: $(stack::not_ready_reason)."
                  if stack::server_failed; then
                      ui::note 'It failed to start. Read the cause with:  ./tc logs server'
                  else
                      ui::note 'Run  ./tc token  and complete that step first.'
                  fi
                  return 1 ;;
    esac

    if admin::exists; then
        local n; n=$(stack::user_count)
        ui::ok "An account already exists ($n user(s)); nothing to do."
        ui::note 'Add further users in TeamCity: Administration → Users.'
        return 0
    fi

    local user=${TC_ADMIN_USER:-admin}
    local pass=${TC_ADMIN_PASSWORD:-}

    if [[ -z $pass ]]; then
        pass=$(validate::gen_password)
        ui::note 'No TC_ADMIN_PASSWORD set, so one was generated for this run.'
    fi

    ui::info "Creating administrator '$user'…"

    admin::_create "$user" "$pass"
    case $? in
        0) ;;
        2) ui::warn "Account '$user' was created but the SYSTEM_ADMIN role was not granted."
           ui::note 'Grant it under Administration → Users, or delete the account and retry.'
           return 1 ;;
        *) ui::err "Could not create '$user'."
           ui::note 'The account may already exist, or the server rejected the password.'
           ui::note "TeamCity's password policy applies here as it would in the browser."
           return 1 ;;
    esac

    ui::blank
    ui::ok "Administrator '$user' created with full system rights."
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
    ui::note "Sign in at $(conf::url)/login.html"

    # Deliberately not written anywhere: the database now holds it, and a
    # generated password echoed once is better than a second copy on disk that
    # drifts the moment it is changed in the UI.
    if [[ -z ${TC_ADMIN_PASSWORD:-} ]]; then
        ui::note 'This password is shown once and not stored — note it now, or'
        ui::note 'change it in TeamCity under your profile.'
    fi

    log::info admin.bootstrap "created administrator '$user' with SYSTEM_ADMIN"
    return 0
}

# Resets the password of an existing administrator and shows the new one once.
#
# For the case the bootstrap creates: an account that exists, works, and whose
# password went past in a scrollback nobody kept.
admin::reset_password() {
    ui::scope admin
    stack::installed || { ui::err 'No stack configured.'; return 1; }

    ui::head 'Reset administrator password'

    if [[ $(stack::server_state) != ready ]]; then
        ui::err "TeamCity is not ready: $(stack::not_ready_reason)."
        ui::note 'Start it with  ./tc up  and try again.'
        return 1
    fi

    local user=${1:-${TC_ADMIN_USER:-admin}}

    if ! agents::_rest GET "/app/rest/users/username:$user" >/dev/null 2>&1; then
        ui::err "No account '$user' on this server."
        ui::note 'List the accounts in TeamCity: Administration → Users.'
        return 1
    fi

    local pass=${TC_ADMIN_PASSWORD:-}
    if [[ -z $pass ]]; then
        pass=$(validate::gen_password)
        ui::note 'No TC_ADMIN_PASSWORD set, so a new one was generated.'
    fi

    if ! admin::_set_password "$user" "$pass"; then
        ui::err "Could not set the password for '$user'."
        ui::note "TeamCity's password policy applies here as it would in the browser."
        ui::note 'If the server rejected it, set TC_ADMIN_PASSWORD and retry.'
        return 1
    fi

    # Proving it rather than reporting it. A 200 on the PUT means the request was
    # accepted; it does not mean the credential works, and the whole point of
    # this command is that someone is locked out.
    if agents::_rest_as "$user" "$pass" GET /app/rest/users/username:"$user" >/dev/null 2>&1; then
        ui::blank
        ui::ok "Password reset and verified — '$user' can sign in with it now."
    else
        ui::blank
        ui::warn "The password was set, but signing in with it did not work."
        ui::note 'Check TeamCity has not locked the account, then retry.'
    fi

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
    ui::note "Sign in at $(conf::url)/login.html"
    ui::note 'Shown once and not stored. Note it now, or change it under your profile.'
}
