#!/usr/bin/env bash
#
# ui.sh — presentation primitives.
#
# House rule, and the reason this file exists: every piece of chrome writes to
# stderr, and only values write to stdout. That is what makes
#
#     port=$(ui::ask 'HTTP port' 8111 validate::port)
#
# capture the port and nothing else, while the prompt, the re-prompts and the
# failure reasons still reach the terminal.

# --- theme --------------------------------------------------------------------

UI_ACCENT='212'   # pink   - selection, focus
UI_INFO='39'      # blue   - neutral emphasis
UI_OK='42'        # green
UI_WARN='214'     # amber
UI_ERR='203'      # red
UI_MUTE='245'     # grey   - secondary text

ui::interactive() { [[ -t 0 && -t 1 && -z ${NO_COLOR:-} ]]; }
ui::plain()       { ! ui::interactive; }

ui::width() {
    local cols
    cols=$(tput cols 2>/dev/null || echo 80)
    (( cols > 100 )) && cols=100
    (( cols < 40 )) && cols=40
    printf '%s' "$cols"
}

# --- messages -----------------------------------------------------------------
#
# All to stderr. Deliberate: these interleave with captured command output.

# One implementation, so plain mode cannot drift from styled mode. Piped output
# must stay free of escape sequences — `./tc status | grep` should not have to
# know about colour.
ui::_msg() {
    local colour=$1 tag=$2; shift 2
    if ui::plain; then
        if [[ -z $tag ]]; then printf '        %s\n' "$*" >&2
        else printf '%-7s %s\n' "$tag" "$*" >&2
        fi
        return
    fi
    if [[ -z $tag ]]; then
        printf '\033[38;5;%sm        %s\033[0m\n' "$colour" "$*" >&2
    else
        printf '\033[38;5;%sm%-7s\033[0m %s\n' "$colour" "$tag" "$*" >&2
    fi
}

# Each also emits a log line. Routing it here rather than at every call site is
# what makes the record complete without touching hundreds of places; UI_SCOPE
# is set by whichever module is running so the line lands in the right file.
UI_SCOPE='console'

ui::ok()   { ui::_msg "$UI_OK"   'ok'    "$@"; log::info  "$UI_SCOPE" "$*"; }
ui::warn() { ui::_msg "$UI_WARN" 'warn'  "$@"; log::warn  "$UI_SCOPE" "$*"; }
ui::err()  { ui::_msg "$UI_ERR"  'error' "$@"; log::error "$UI_SCOPE" "$*"; }
ui::info() { ui::_msg "$UI_INFO" 'info'  "$@"; log::debug "$UI_SCOPE" "$*"; }
ui::note() { ui::_msg "$UI_MUTE" ''      "$@"; }

# Modules announce themselves so their messages are filed correctly.
ui::scope() { UI_SCOPE=$1; }
ui::blank(){ printf '\n' >&2; }

# A heading for a section of output.
ui::head() {
    local text=$*
    ui::blank
    if ui::plain; then
        printf '== %s ==\n' "$text" >&2
        return
    fi
    local rule width=${#text}
    (( width > 60 )) && width=60
    printf -v rule '─%.0s' $(seq 1 "$width")
    printf '\033[1;38;5;%sm%s\033[0m\n' "$UI_ACCENT" "$text" >&2
    printf '\033[38;5;%sm%s\033[0m\n' "$UI_MUTE" "$rule" >&2
}

# --- banner -------------------------------------------------------------------

# ui::banner <stack> <version> <state> <url> <agents>
#   state: running | stopped | partial | absent
ui::banner() {
    local stack=$1 version=$2 state=$3 url=$4 agents=$5
    local dot colour

    case $state in
        running) dot='●'; colour=$UI_OK ;;
        partial) dot='◐'; colour=$UI_WARN ;;
        stopped) dot='○'; colour=$UI_MUTE ;;
        *)       dot='·'; colour=$UI_MUTE ;;
    esac

    if ui::plain; then
        printf 'TeamCity Control Console  %s %s  %s  %s  %s\n' \
            "$stack" "$version" "$state" "$url" "$agents" >&2
        return
    fi

    local line1 line2
    line1=$(printf '\033[1mTeamCity Control Console\033[0m   \033[38;5;%sm%s · %s\033[0m' \
        "$UI_MUTE" "$stack" "$version")
    line2=$(printf '\033[38;5;%sm%s %s\033[0m   \033[38;5;%sm%s\033[0m   \033[38;5;%sm%s\033[0m' \
        "$colour" "$dot" "$state" "$UI_INFO" "$url" "$UI_MUTE" "$agents")

    gum style --border rounded --border-foreground "$UI_ACCENT" \
        --padding '0 2' --margin '1 0 0 0' --width "$(( $(ui::width) - 4 ))" \
        "$line1" "$line2" >&2
}

# --- menu ---------------------------------------------------------------------

# ui::menu <header> <label>|<gloss> ...
# Echoes the chosen label (the part before the first '|') on stdout.
ui::menu() {
    local header=$1; shift
    local -a display=() labels=()
    local entry label gloss

    for entry in "$@"; do
        label=${entry%%|*}
        gloss=${entry#*|}
        labels+=("$label")
        if [[ $gloss == "$label" ]]; then
            display+=("$label")
        else
            display+=("$(printf '%-24s %s' "$label" "$gloss")")
        fi
    done

    if ui::plain; then
        printf '%s\n' "$header" >&2
        local i
        for i in "${!labels[@]}"; do printf '  %2d) %s\n' "$((i+1))" "${display[$i]}" >&2; done
        printf 'Selection: ' >&2
        local pick; read -r pick
        if [[ ! $pick =~ ^[0-9]+$ ]] || (( pick < 1 || pick > ${#labels[@]} )); then
            ui::err 'Not a valid selection.'
            return 1
        fi
        printf '%s' "${labels[$((pick-1))]}"
        return
    fi

    local chosen
    chosen=$(printf '%s\n' "${display[@]}" | gum choose \
        --header "$header" \
        --header.foreground "$UI_ACCENT" \
        --cursor '▸ ' \
        --cursor.foreground "$UI_ACCENT" \
        --height "$(ui::menu_height ${#display[@]})") || return 1

    # Match on the label prefix rather than the whole rendered line. The display
    # string is padded, and requiring it to survive gum byte-for-byte made
    # selection depend on whitespace handling — an entry with an empty gloss
    # carried 21 trailing spaces, and any trimming dropped the user out of the
    # menu with no message. Comparing the leading label is stable either way.
    local i
    for i in "${!labels[@]}"; do
        if [[ $chosen == "${labels[$i]}" || $chosen == "${labels[$i]} "* ]]; then
            printf '%s' "${labels[$i]}"
            return 0
        fi
    done
    return 1
}

# Fit the chooser to the terminal, leaving room for the banner and header.
ui::menu_height() {
    local items=$1 lines
    lines=$(tput lines 2>/dev/null || echo 24)
    local avail=$(( lines - 8 ))
    (( avail < 5 )) && avail=5
    (( items < avail )) && avail=$items
    printf '%s' "$avail"
}

# --- prompts ------------------------------------------------------------------

# ui::ask <prompt> <default> [validator]
#
# Loops until the validator accepts. The validator is a function name; it
# receives the candidate value, prints its objection to stderr, and returns
# non-zero to reject. The accepted value goes to stdout.
ui::ask() {
    local prompt=$1 default=${2:-} validator=${3:-}
    local value

    while true; do
        if ui::plain; then
            printf '%s [%s]: ' "$prompt" "$default" >&2
            read -r value
        else
            value=$(gum input \
                --prompt "$(printf '%s ' "$prompt")" \
                --prompt.foreground "$UI_ACCENT" \
                --placeholder "$default" \
                --value "$default" \
                --width "$(ui::width)") || return 1
        fi

        [[ -z $value ]] && value=$default

        if [[ -z $validator ]] || "$validator" "$value"; then
            printf '%s' "$value"
            return 0
        fi
    done
}

# ui::secret <prompt> <default> [validator] — masked input.
ui::secret() {
    local prompt=$1 default=${2:-} validator=${3:-}
    local value

    while true; do
        if ui::plain; then
            printf '%s (hidden, enter to accept generated): ' "$prompt" >&2
            read -rs value; printf '\n' >&2
        else
            value=$(gum input --password \
                --prompt "$(printf '%s ' "$prompt")" \
                --prompt.foreground "$UI_ACCENT" \
                --placeholder 'enter to accept the generated value' \
                --width "$(ui::width)") || return 1
        fi

        [[ -z $value ]] && value=$default

        if [[ -z $validator ]] || "$validator" "$value"; then
            printf '%s' "$value"
            return 0
        fi
    done
}

# ui::choose <header> <option>... — a plain chooser returning the option itself.
ui::choose() {
    local header=$1; shift
    if ui::plain; then
        ui::menu "$header" "$@"
        return
    fi
    printf '%s\n' "$@" | gum choose \
        --header "$header" \
        --header.foreground "$UI_ACCENT" \
        --cursor '▸ ' \
        --cursor.foreground "$UI_ACCENT" \
        --height 16
}

# --- confirmation -------------------------------------------------------------

ui::confirm() {
    local prompt=$1 default=${2:-no}
    if ui::plain; then
        printf '%s [y/N]: ' "$prompt" >&2
        local reply; read -r reply
        [[ $reply =~ ^[Yy] ]]
        return
    fi
    if [[ $default == yes ]]; then
        gum confirm "$prompt" --affirmative 'Yes' --negative 'No'
    else
        gum confirm "$prompt" --affirmative 'Yes' --negative 'No' --default=false
    fi
}

# ui::confirm_typed <word> <warning...>
#
# Used for anything destructive. A y/n prompt is too easy to hit by reflex when
# the cost is "every build, project and agent token is gone".
ui::confirm_typed() {
    local word=$1; shift
    ui::blank
    ui::warn "$*"
    ui::note "Type '$word' to proceed, anything else to cancel."

    local typed
    if ui::plain; then
        printf 'Confirm: ' >&2; read -r typed
    else
        typed=$(gum input --prompt 'Confirm ' --prompt.foreground "$UI_ERR" \
            --placeholder "$word") || return 1
    fi

    [[ $typed == "$word" ]] || { ui::note 'Cancelled.'; return 1; }
}

# --- progress -----------------------------------------------------------------

# ui::spin <title> -- <command...>
#
# `gum spin` forks and EXECS its argument, so it can only run a real binary. Pass
# it a shell function — `stack::compose`, say — and it fails with
#
#     exec: "stack::compose": executable file not found in $PATH
#
# and because the plain-mode branch below calls "$@" directly, that failure is
# invisible to any test that is not attached to a terminal. Detecting the case
# here fixes every call site at once and keeps the spinner for real commands.
ui::spin() {
    local title=$1; shift
    [[ ${1:-} == '--' ]] && shift

    if ui::plain || declare -F "$1" >/dev/null 2>&1; then
        ui::info "$title"
        "$@"
        return
    fi
    gum spin --spinner dot --title "$title" --show-error -- "$@"
}

# --- status rows --------------------------------------------------------------
#
# Checklist output for preflight and verify. One implementation, so the two
# cannot drift in colour, alignment or plain-mode behaviour — they carried three
# near-identical copies between them.

UI_ROW_WIDTH=40

# ui::row <colour> <glyph> <plain-tag> <label> [detail]
ui::row() {
    local colour=$1 glyph=$2 tag=$3 label=$4 detail=${5:-}
    if ui::plain; then
        printf '  %-4s %-*s %s\n' "$tag" "$UI_ROW_WIDTH" "$label" "$detail" >&2
    else
        printf '  \033[38;5;%sm%s\033[0m %-*s %s\n' \
            "$colour" "$glyph" "$UI_ROW_WIDTH" "$label" "$detail" >&2
    fi
}

ui::row_pass() { ui::row "$UI_OK"   '✓' 'PASS' "$@"; }
ui::row_warn() { ui::row "$UI_WARN" '!' 'WARN' "$@"; }
ui::row_fail() { ui::row "$UI_ERR"  '✗' 'FAIL' "$@"; }
ui::row_skip() { ui::row "$UI_MUTE" '–' 'SKIP' "$@"; }

# The remedy line under a row.
ui::hint() {
    if ui::plain; then printf '       -> %s\n' "$1" >&2
    else printf '    \033[38;5;%sm↳ %s\033[0m\n' "$UI_MUTE" "$1" >&2
    fi
}

# --- pause --------------------------------------------------------------------

ui::pause() {
    ui::plain && return 0
    ui::blank
    ui::note 'Press enter to return to the menu.'
    read -r _ || true
}
