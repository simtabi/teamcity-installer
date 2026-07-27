#!/usr/bin/env bash
#
# log.sh — the console's own record, one file per tool under logs/.
#
# `./tc logs` shows the *containers'* logs. This is the console's own behaviour:
# what it decided, what it ran, and why it refused. Without it, a failure leaves
# only whatever scrolled past, and the next menu redraw takes even that away.
#
# Format, one line per event:
#
#   2026-07-27T13:45:02-04:00  INFO   a3f1  stack.up      teamcity  compose up -d
#   └ timestamp                └ level └ id  └ tool.action └ stack   └ message
#
# Column-aligned so it reads down the page, single-space delimited so `cut` and
# `awk` work. The session id is fixed for one ./tc invocation, so a single run
# can be isolated with `grep a3f1 logs/*.log` even when runs interleave.

LOG_DIR="${TC_ROOT:-$PWD}/logs"

: "${TC_LOG_LEVEL:=INFO}"     # DEBUG | INFO | WARN | ERROR | OFF
: "${TC_LOG_MAX_KB:=2048}"    # rotate past this size
: "${TC_LOG_KEEP:=5}"         # how many rotations to keep

# Fixed for the life of one invocation. /dev/urandom rather than $RANDOM so
# concurrent runs starting in the same second do not collide.
TC_SESSION="${TC_SESSION:-$(head -c 2 /dev/urandom 2>/dev/null | od -An -tx1 | tr -d ' \n' || printf '%04x' $$)}"

log::_level_num() {
    case ${1^^} in
        DEBUG) printf 10 ;; INFO) printf 20 ;;
        WARN)  printf 30 ;; ERROR) printf 40 ;;
        OFF)   printf 99 ;; *) printf 20 ;;
    esac
}

# --- redaction ----------------------------------------------------------------
#
# This surface writes continuously and lands on disk, so redaction is a hard
# requirement rather than a nicety. Two layers: the exact secret values this
# stack knows about, and a pattern sweep for anything that looks like a secret
# regardless of where it came from.

log::_redact() {
    local line=$1

    [[ -n ${TC_PG_PASSWORD:-} ]] && line=${line//"$TC_PG_PASSWORD"/'«redacted»'}

    local token
    if token=$(conf::token 2>/dev/null) && [[ -n $token ]]; then
        line=${line//"$token"/'«redacted»'}
    fi

    # Anything shaped like a credential, whoever produced it.
    line=$(printf '%s' "$line" | sed -E \
        -e 's/([Pp]assword[=:[:space:]]+)[^[:space:]]+/\1«redacted»/g' \
        -e 's/([Tt]oken[=:[:space:]]+)[^[:space:]]+/\1«redacted»/g' \
        -e 's/(Bearer[[:space:]]+)[^[:space:]]+/\1«redacted»/g' \
        -e 's/(POSTGRES_PASSWORD[=:])[^[:space:]]+/\1«redacted»/g')

    printf '%s' "$line"
}

# --- rotation -----------------------------------------------------------------
#
# Size-based and dependency-free. Logs must not repeat the mistake backups made
# of growing without bound.

log::_rotate_if_needed() {
    local file=$1
    [[ -f $file ]] || return 0

    local kb; kb=$(( $(wc -c <"$file" 2>/dev/null || echo 0) / 1024 ))
    (( kb >= TC_LOG_MAX_KB )) || return 0

    local i
    for (( i = TC_LOG_KEEP - 1; i >= 1; i-- )); do
        [[ -f "$file.$i" ]] && mv -f "$file.$i" "$file.$(( i + 1 ))"
    done
    mv -f "$file" "$file.1"
    rm -f "$file.$(( TC_LOG_KEEP + 1 ))"
    return 0
}

# --- writing ------------------------------------------------------------------

# log::write <level> <tool.action> <message...>
#
# The tool part before the dot picks the file, so log::write stack.up … lands in
# logs/stack.log. Never fails the caller: logging must not be able to break the
# operation it is describing.
log::write() {
    local level=${1^^} scope=$2; shift 2
    local message="$*"

    (( $(log::_level_num "$level") >= $(log::_level_num "$TC_LOG_LEVEL") )) || return 0
    [[ ${TC_LOG_LEVEL^^} == OFF ]] && return 0

    local tool=${scope%%.*}
    local file="$LOG_DIR/${tool}.log"

    mkdir -p "$LOG_DIR" 2>/dev/null || return 0
    log::_rotate_if_needed "$file"

    printf '%s  %-5s  %s  %-16s %-12s %s\n' \
        "$(date +%Y-%m-%dT%H:%M:%S%z)" \
        "$level" \
        "$TC_SESSION" \
        "$scope" \
        "${TC_STACK:--}" \
        "$(log::_redact "$message")" \
        >>"$file" 2>/dev/null || true

    return 0
}

log::debug() { log::write DEBUG "$@"; }
log::info()  { log::write INFO  "$@"; }
log::warn()  { log::write WARN  "$@"; }
log::error() { log::write ERROR "$@"; }

# Records a command line before it runs. Every docker/compose invocation goes
# through here — when reconstructing a failure, knowing exactly what was executed
# is worth more than any amount of prose.
log::cmd() {
    local scope=$1; shift
    log::write DEBUG "$scope" "exec: $*"
}

# log::result <scope> <exit-code> <what>
log::result() {
    local scope=$1 rc=$2; shift 2
    if (( rc == 0 )); then log::write INFO  "$scope" "ok: $* (exit 0)"
    else                   log::write ERROR "$scope" "failed: $* (exit $rc)"
    fi
    return "$rc"
}

# --- reading ------------------------------------------------------------------

log::tools() {
    printf '%s\n' console wizard stack agents backup upgrade doctor verify
}

log::show() {
    local tool=${1:-} follow=${2:-}

    mkdir -p "$LOG_DIR"

    if [[ -z $tool ]]; then
        local -a available=()
        local t
        for t in $(log::tools); do [[ -f "$LOG_DIR/$t.log" ]] && available+=("$t"); done
        available+=('all')

        if (( ${#available[@]} == 1 )); then
            ui::warn 'No console logs yet — nothing has been run in this project.'
            return 1
        fi
        tool=$(ui::choose 'Which log?' "${available[@]}") || return 0
    fi

    if [[ $tool == all ]]; then
        ui::head 'Console log — all tools, newest last'
        # Interleave by timestamp so a session reads in order across files.
        sort -m -k1,1 "$LOG_DIR"/*.log 2>/dev/null | tail -200
        return 0
    fi

    local file="$LOG_DIR/$tool.log"
    if [[ ! -f $file ]]; then
        ui::err "No log for '$tool' yet."
        ui::note "Tools that log: $(log::tools | tr '\n' ' ')"
        return 1
    fi

    ui::head "Console log — $tool"
    ui::note "$file"
    ui::blank

    if [[ $follow == follow ]]; then
        ui::note 'Ctrl-C stops following.'
        trap ':' INT
        tail -n 50 -f "$file" || true
        trap - INT
    else
        tail -n 200 "$file"
    fi
}

# Everything this session wrote, across every tool.
log::session() {
    mkdir -p "$LOG_DIR"
    ui::head "Console log — session $TC_SESSION"
    grep -h "  $TC_SESSION  " "$LOG_DIR"/*.log 2>/dev/null | sort || {
        ui::note 'Nothing logged in this session yet.'
        return 0
    }
}
