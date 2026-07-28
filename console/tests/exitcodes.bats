#!/usr/bin/env bats
#
# Exit-code hygiene.
#
# Bash's sharpest edge in this codebase: a function whose last statement is a
# bare `cond && action` returns the exit code of that test. When the condition
# is false the function reports failure despite having done its job.
#
# It bit twice. backup::_cold ended with `[[ -n $pg_major ]] && ui::note …`,
# which is false on an HSQLDB stack — so a successful backup returned 1 and
# aborted an upgrade with "Backup failed". doctor::_storage had the same shape.
#
# This test reads the sources rather than calling the functions, because the
# failure is structural and cheap to detect that way.

load helper

setup() { load_libs; }

@test "no function ends in a bare conditional-and" {
    local offenders=''

    for f in "$LIB"/*.sh; do
        # Join line continuations so a two-line `cond \<newline>&& action`
        # is seen as the single statement it is.
        offenders+=$(awk -v F="$(basename "$f")" '
            { line = $0
              while (line ~ /\\$/) { sub(/\\$/, "", line); if ((getline nxt) > 0) line = line " " nxt }
              if (line ~ /^[a-z][a-z:_]*\(\)/) fn = line
              if (line ~ /^\}/) {
                  if (prev ~ /&&/ && prev !~ /(return|exit|\|\||docker |^[[:space:]]*(if|while|for|case))/)
                      printf "%s %s -> %s\n", F, fn, prev
                  prev = ""
                  next
              }
              if (line ~ /[^[:space:]]/ && line !~ /^[[:space:]]*#/) prev = line
            }' "$f")
    done

    [ -z "$offenders" ] || { echo "$offenders"; return 1; }
}

# The specific regression, exercised rather than inspected.
@test "cold backup reports success on a stack with no PostgreSQL" {
    default_conf
    TC_DB=hsqldb

    # Stand in for the work; only the return path is under test.
    stack::state()          { printf 'stopped'; }
    stack::compose()        { return 0; }
    render::volume_names()  { printf '%s_datadir\n' "$TC_STACK"; }
    backup::_tar_volume()   { return 0; }
    backup::_write_manifest() { return 0; }
    backup::_pg_major()     { printf ''; }
    ui::spin()              { return 0; }
    docker()                { return 0; }
    du()                    { printf '24K\t-\n'; }

    run backup::_cold
    [ "$status" -eq 0 ]
}

# --- timeouts must not exec shell functions -----------------------------------
#
# `timeout cmd` and `gum spin -- cmd` both exec their argument, so neither can
# run a shell function. That cost the project every ui::spin call site once; the
# backup deadline in verify.sh was about to repeat it.

@test "no shell function is handed to timeout" {
    local offenders=''
    local f cmd
    for f in "$LIB"/*.sh; do
        while IFS= read -r cmd; do
            [[ -z $cmd ]] && continue
            [[ $cmd == *::* ]] && offenders+="$f: timeout $cmd"$'\n'
        done < <(grep -hoE 'timeout +"?\$?[a-zA-Z_{}]+"? +[a-zA-Z_:]+' "$f" 2>/dev/null \
                 | awk '{print $NF}')
    done
    [ -z "$offenders" ] || { echo "$offenders"; return 1; }
}

@test "the backup deadline uses a background job, not timeout" {
    grep -q 'kill -0 "$pid"' "$LIB/verify.sh"
}
