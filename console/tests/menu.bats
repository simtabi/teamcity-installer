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
