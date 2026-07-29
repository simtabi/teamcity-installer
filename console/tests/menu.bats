#!/usr/bin/env bats
#
# Menu integrity.
#
# The menu used to hold its entries in one place and its handlers in another, so
# nothing could enumerate it and "test every menu entry" meant clicking through
# by hand. A single table makes it a property instead: every entry must name a
# handler that exists.

load helper

setup() {
    load_libs
    default_conf
    # main.sh guards its entry point on BASH_SOURCE, so sourcing it loads every
    # module and the menu table without launching the console.
    # shellcheck disable=SC1090
    source "$LIB/main.sh"
}

@test "every installed-menu entry names a handler that exists" {
    local entry handler missing=''
    for entry in "${TC_MENU[@]}"; do
        handler=${entry##*|}
        declare -F "$handler" >/dev/null 2>&1 || missing+="${entry%%|*} -> $handler"$'\n'
    done
    [ -z "$missing" ] || { echo "$missing"; return 1; }
}

@test "every pre-install entry names a handler that exists" {
    local entry handler missing=''
    for entry in "${TC_MENU_UNINSTALLED[@]}"; do
        handler=${entry##*|}
        declare -F "$handler" >/dev/null 2>&1 || missing+="${entry%%|*} -> $handler"$'\n'
    done
    [ -z "$missing" ] || { echo "$missing"; return 1; }
}

@test "every entry has all three fields" {
    local entry
    for entry in "${TC_MENU[@]}" "${TC_MENU_UNINSTALLED[@]}"; do
        [ "$(printf '%s' "$entry" | tr -cd '|' | wc -c)" -eq 2 ] \
            || { echo "malformed: $entry"; return 1; }
        [ -n "${entry%%|*}" ] || { echo "empty label: $entry"; return 1; }
        [ -n "${entry##*|}" ] || { echo "empty handler: $entry"; return 1; }
    done
}

@test "labels are unique — the chooser maps back by label" {
    local -a labels=()
    local entry
    for entry in "${TC_MENU[@]}"; do labels+=("${entry%%|*}"); done
    [ "$(printf '%s\n' "${labels[@]}" | sort -u | wc -l)" -eq "${#labels[@]}" ]
}

@test "no label is a prefix of another — prefix matching must stay unambiguous" {
    local a b
    for a in "${TC_MENU[@]}"; do
        for b in "${TC_MENU[@]}"; do
            [ "${a%%|*}" = "${b%%|*}" ] && continue
            [[ ${b%%|*} == "${a%%|*}"* ]] && { echo "'${a%%|*}' is a prefix of '${b%%|*}'"; return 1; }
        done
    done
    return 0
}

@test "both menus offer a way out" {
    printf '%s\n' "${TC_MENU[@]}" | grep -q '^Quit|'
    printf '%s\n' "${TC_MENU_UNINSTALLED[@]}" | grep -q '^Quit|'
}

# --- the front ends must stay complete ----------------------------------------
#
# Three surfaces expose the same functionality: the menu, ./tc commands, and
# make targets. A capability added to one and forgotten in the others is
# invisible until somebody goes looking for it.

@test "every ./tc command has a make target" {
    local project="${PROJECT_ROOT:?}"
    [ -f "$project/Makefile" ] || skip 'Makefile not reachable'

    local -a commands targets missing=()
    mapfile -t commands < <(sed -n '/main::run_command() {/,/^}/p' "$LIB/main.sh" \
        | grep -oE '^        [a-z|-]+\)' | tr -d ' )' | tr '|' '\n' \
        | grep -vE '^(help|--help|-h)$' | sort -u)
    mapfile -t targets < <(grep -oE '^[a-z-]+( [a-z-]+)*:' "$project/Makefile" \
        | tr -d ':' | tr ' ' '\n' | sort -u)

    local c t found
    for c in "${commands[@]}"; do
        found=0
        for t in "${targets[@]}"; do [ "$c" = "$t" ] && { found=1; break; }; done
        (( found )) || missing+=("$c")
    done

    [ ${#missing[@]} -eq 0 ] || { echo "commands with no make target: ${missing[*]}"; return 1; }
}

@test "every menu action is reachable from the command line" {
    local -a handlers=() missing=()
    local entry handler cmd
    for entry in "${TC_MENU[@]}"; do
        handler=${entry##*|}
        # Submenus and Quit are inherently interactive. What matters is that the
        # actions *inside* them are scriptable, which the command audit covers.
        case $handler in
            main::quit|*::menu|main::doctor_menu) continue ;;
        esac
        grep -q "$handler" <(sed -n '/main::run_command() {/,/^}/p' "$LIB/main.sh") \
            || missing+=("${entry%%|*} -> $handler")
    done
    [ ${#missing[@]} -eq 0 ] || { echo "menu-only actions: ${missing[*]}"; return 1; }
}

# --- capabilities the CLI can reach --------------------------------------------
#
# `backup::list` existed from the start and was reachable only from the menu, so
# nothing could script it — the same gap that once left shell, open, reconfigure
# and prune menu-only. A function that shows the user something is a capability;
# if the CLI cannot ask for it, it is half-built.

@test "every backup kind the error message advertises is dispatched" {
    local msg kinds kind
    msg=$(grep -o "Use native, logical[^\"']*" "$LIB/main.sh" | head -1)
    kinds=$(printf '%s' "$msg" | sed 's/Use //; s/ or /, /; s/\.$//')
    IFS=',' read -ra list <<< "$kinds"
    for kind in "${list[@]}"; do
        kind=$(printf '%s' "$kind" | tr -d ' ')
        grep -qE "^ *$kind\)" "$LIB/main.sh" \
            || { echo "advertised but not dispatched: $kind"; return 1; }
    done
}

@test "backup list is reachable from the command line" {
    grep -qE '^ *list\) *ui::scope backup; backup::list' "$LIB/main.sh"
}

@test "the help text names every backup kind that works" {
    run grep 'tc backup \[kind\]' "$LIB/main.sh"
    local k
    for k in native logical cold list; do
        [[ $output == *"$k"* ]] || { echo "help omits: $k"; return 1; }
    done
}

@test "an unknown backup kind exits non-zero rather than merely complaining" {
    # Piping ./tc into anything hides its exit status behind the last command in
    # the pipeline, so this is easy to believe fixed when it is not.
    run grep -A10 'Unknown backup kind' "$LIB/main.sh"
    [[ $output == *'return 2'* ]] || { echo 'an unknown kind reports and continues'; return 1; }
}

# --- password recovery ---------------------------------------------------------
#
# The bootstrap generates a password, shows it once and deliberately never writes
# it down. That is the right call — a second copy on disk goes stale the moment
# it changes in the UI — but it creates a way to be locked out of an account that
# exists and works, and the documented recovery was "open a browser and click
# through six screens you have never seen".

@test "admin reset is reachable from the command line" {
    grep -qE 'admin\).*reset' "$LIB/main.sh" \
        || { echo 'the reset path is not dispatched'; return 1; }
    # Routed to the single implementation in users.sh rather than a second copy.
    grep -q 'users::passwd' "$LIB/main.sh"
}

@test "the help text mentions the recovery, or nobody will find it" {
    run grep 'tc admin reset' "$LIB/main.sh"
    [ "$status" -eq 0 ]
}

@test "the reset proves the new credential rather than trusting the response" {
    # A 200 on the PUT means the request was accepted, not that anyone can sign
    # in with the result — and being unable to sign in is the entire problem.
    run grep -A4 '^users::_verify()' "$LIB/users.sh"
    [[ $output == *'_rest_as'* ]]
}

@test "the credential check does not fall back to another identity" {
    # Every other REST call falls back: stored token, then super user token. Here
    # that would answer "yes, authenticated" for a password that does not work.
    run grep -A12 '^agents::_rest_as()' "$LIB/agents.sh"
    [[ $output == *'--user'* ]]
    [[ $output != *'_auth_args'* ]] || { echo 'the proof falls back to another identity'; return 1; }
}

@test "reset refuses on a server that is not ready, and says why" {
    run grep -A12 '^users::passwd()' "$LIB/users.sh"
    [[ $output == *'not_ready_reason'* ]]
}
