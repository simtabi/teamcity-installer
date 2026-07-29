#!/usr/bin/env bats
#
# Users.
#
# The account this tool creates can be lost: `./tc admin` generates a password,
# prints it once and deliberately never writes it down. That is the right call —
# a second copy on disk goes stale the moment it changes in the UI — but it means
# an account can exist, work, hold every permission, and be unreachable.
#
# The way back is the super user token, which TeamCity writes to its log on every
# start. So these tests care about one property above all: setting a password
# must never depend on knowing one, and must never *claim* success it has not
# checked.

load helper

setup() {
    load_libs; default_conf; ui_speaks
    # shellcheck disable=SC1090
    source "$LIB/stack.sh"
    # shellcheck disable=SC1090
    source "$LIB/agents.sh"
    # shellcheck disable=SC1090
    source "$LIB/users.sh"
}

# --- timestamps ----------------------------------------------------------------

@test "TeamCity's basic-format timestamp is made readable" {
    [ "$(users::_when '20260729T092018-0400')" = '2026-07-29 09:20' ]
}

@test "an account that never signed in says so rather than showing nothing" {
    [ "$(users::_when '')" = 'never' ]
    [ "$(users::_when 'null')" = 'never' ]
}

@test "an unrecognised timestamp is passed through, not blanked" {
    # Losing the value entirely would be worse than showing it oddly.
    [ "$(users::_when '2026-07-29 09:20:18')" = '2026-07-29 09:20:18' ]
}

# --- the property that matters -------------------------------------------------

@test "verification uses the credential under test, with no fallback" {
    # agents::_rest falls back through the stored access token and then the super
    # user token. Used here it would answer "authenticated" for a password that
    # does not work at all — the one answer that must never be wrong.
    run grep -A4 '^users::_verify()' "$LIB/users.sh"
    [[ $output == *'agents::_rest_as'* ]] || { echo 'verification can fall back'; return 1; }
    [[ $output != *'agents::_rest '* ]]
}

@test "setting a password never requires knowing one" {
    # It goes through the console's normal REST auth, which reaches for the super
    # user token when nothing else is available. That is the whole recovery.
    run grep -A3 '^users::_set_password()' "$LIB/users.sh"
    [[ $output == *'agents::_rest PUT'* ]]
    [[ $output == *'/password'* ]]
}

@test "a password is read from stdin, not from an environment variable" {
    # The launcher passes a fixed set of variables into the container, so a
    # TC_NEW_PASSWORD on the host never arrives: the scripted path would look
    # supported and silently generate a password instead.
    # Mentioned in a comment explaining why it is not used; never read.
    run grep -vE '^\s*#' "$LIB/users.sh"
    [[ $output != *'TC_NEW_PASSWORD'* ]] || { echo 'still reads an environment variable'; return 1; }
    run grep -A4 'if \[\[ ! -t 0 \]\]' "$LIB/users.sh"
    [[ $output == *'read -r pass'* ]]
}

@test "an empty stdin generates rather than hanging or setting a blank password" {
    run grep -A6 'if \[\[ ! -t 0 \]\]' "$LIB/users.sh"
    [[ $output == *'|| true'* ]]                 # EOF must not abort under set -e
    run grep -A3 'if \[\[ -z \$pass \]\]; then' "$LIB/users.sh"
    [[ $output == *'gen_password'* ]]
}

@test "a chosen password is not echoed back, only a generated one" {
    run grep -B2 -A3 'if (( generated )); then' "$LIB/users.sh"
    [[ $output == *'generated'* ]]
}

# --- one implementation --------------------------------------------------------

@test "only users.sh sets passwords" {
    # admin.sh grew its own copy first. Two implementations of the same operation
    # is how this console ended up with one defect in three places.
    local f offenders=0
    for f in "$LIB"/*.sh; do
        [[ $(basename "$f") == users.sh ]] && continue
        grep -q 'users/username:[^/]*/password' "$f" && {
            echo "$(basename "$f") sets passwords too"; offenders=$((offenders+1)); }
    done
    [ "$offenders" -eq 0 ]
}

@test "admin reset routes to the one implementation" {
    grep -q 'users::passwd' "$LIB/main.sh"
    run grep -c 'admin::reset_password' "$LIB/admin.sh"
    [ "$output" -eq 0 ]
}

# --- surfaces ------------------------------------------------------------------

@test "every users action is reachable from the command line" {
    local a
    for a in list show passwd; do
        grep -qE "^ +$a\)" "$LIB/main.sh" || { echo "not dispatched: users $a"; return 1; }
    done
}

@test "the users menu entry points at a function that exists" {
    grep -q "'Users|" "$LIB/main.sh"
    declare -F users::menu >/dev/null
}

@test "help names the users commands" {
    run grep 'tc users' "$LIB/main.sh"
    [[ $output == *'passwd'* ]]
    [[ $output == *'show'* ]]
}

@test "the bootstrap says how to recover, where the risk is created" {
    # Not in a document read only after someone is already locked out.
    run grep -A5 'shown once and not stored' "$LIB/admin.sh"
    [[ $output == *'users passwd'* ]]
}

# --- listing -------------------------------------------------------------------

@test "a server with no accounts is called out, not shown as an empty table" {
    run grep -A5 'if \[\[ \$count == 0 \]\]; then' "$LIB/users.sh"
    [[ $output == *'./tc admin'* ]]
}

@test "a server nobody can administer is called out" {
    # Accounts exist, none can administer, and the UI cannot fix it from inside.
    run grep -A4 'if (( admins == 0 )); then' "$LIB/users.sh"
    [[ $output == *'SYSTEM_ADMIN'* ]]
    [[ $output == *'token'* ]]
}

@test "the listing asks for the fields it needs" {
    # The default response carries no email, no roles and no last login, so a
    # table built from it would silently show blanks for all three.
    [[ $USERS_FIELDS == *'email'* ]]
    [[ $USERS_FIELDS == *'lastLogin'* ]]
    [[ $USERS_FIELDS == *'roles'* ]]
}
