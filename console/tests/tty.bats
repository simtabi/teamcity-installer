#!/usr/bin/env bats
#
# The TTY branch.
#
# This file exists because of the worst bug in the project's history. ui::spin
# branches on whether a terminal is attached:
#
#     if ui::plain; then "$@"; fi          # direct call — works
#     gum spin --title "$t" -- "$@"        # exec — cannot call a shell function
#
# Sixteen call sites passed `stack::compose`, a shell function. Every one failed
# under a real terminal with "executable file not found in $PATH", and every one
# passed in the test suite, because the suite was never attached to a terminal.
#
# `script` allocates a pseudo-terminal, so these tests run the branch users hit.

load helper

setup() { load_libs; }

# Run a snippet with a PTY on stdin and stdout, so ui::plain returns false.
#
# The snippet goes to a file and is run with bash explicitly: `script -c` hands
# the command to /bin/sh, which on Alpine is busybox ash, and the libraries are
# bash.
on_a_tty() {
    local snippet="$BATS_TEST_TMPDIR/snippet.sh"
    printf '%s\n' "$1" >"$snippet"
    script -qec "bash $snippet" /dev/null 2>&1
}

@test "the harness really does allocate a terminal" {
    run on_a_tty 'test -t 1 && echo TTY || echo NOTTY'
    [[ $output == *TTY* ]]
    [[ $output != *NOTTY* ]]
}

@test "ui::plain is false under a terminal and true without one" {
    run on_a_tty "source $LIB/log.sh; source $LIB/ui.sh; ui::plain && echo plain || echo styled"
    [[ $output == *styled* ]]

    run bash -c "source $LIB/log.sh; source $LIB/ui.sh; ui::plain && echo plain || echo styled"
    [[ $output == *plain* ]]
}

# The regression itself.
@test "ui::spin runs a shell function under a terminal" {
    run on_a_tty "
        source $LIB/log.sh; source $LIB/ui.sh
        a_shell_function() { echo 'FUNCTION RAN'; }
        ui::spin 'working' -- a_shell_function"

    [[ $output == *'FUNCTION RAN'* ]]
    [[ $output != *'executable file not found'* ]]
}

@test "ui::spin still runs a real binary under a terminal" {
    run on_a_tty "
        source $LIB/log.sh; source $LIB/ui.sh
        ui::spin 'working' -- /bin/echo BINARY RAN"
    [[ $output != *'executable file not found'* ]]
}

@test "ui::spin propagates a failing function's exit code" {
    run on_a_tty "
        source $LIB/log.sh; source $LIB/ui.sh
        failing() { return 3; }
        ui::spin 'working' -- failing; echo \"rc=\$?\""
    [[ $output == *'rc=3'* ]]
}

# Guards the whole class rather than the one instance: no call site anywhere may
# hand a shell function to the gum branch.
@test "no ui::spin call site would reach gum with a shell function" {
    run bash -c "
        source $LIB/log.sh; source $LIB/ui.sh
        for f in $LIB/*.sh; do source \$f 2>/dev/null || true; done

        bad=''
        for f in $LIB/*.sh; do
            grep -hoE 'ui::spin [^|]*-- [a-zA-Z_:]+' \"\$f\" 2>/dev/null | while read -r line; do
                cmd=\${line##*-- }
                if declare -F \"\$cmd\" >/dev/null 2>&1; then
                    # A function is fine now — ui::spin detects and inlines it.
                    :
                elif ! command -v \"\$cmd\" >/dev/null 2>&1; then
                    echo \"UNRESOLVABLE: \$cmd in \$f\"
                fi
            done
        done"
    [[ $output != *UNRESOLVABLE* ]]
}

@test "messages stay free of escape codes when not on a terminal" {
    run bash -c "source $LIB/log.sh; source $LIB/ui.sh; ui::ok 'plain please' 2>&1"
    [[ $output != *$'\033'* ]]
}
