#!/usr/bin/env bats
#
# The disk guard.
#
# A cold or logical backup writes roughly the size of the volumes it copies, and
# both stop containers partway through. Filling the disk there leaves a stopped
# server and a truncated archive, so the refusal has to happen before any of that
# — being right about the numbers is not enough if it is right too late.

load helper

setup() {
    load_libs; default_conf; ui_speaks
    # shellcheck disable=SC1090
    source "$LIB/render.sh"
    # shellcheck disable=SC1090
    source "$LIB/backup.sh"
}

GB=$(( 1024 * 1024 * 1024 ))
MB=$(( 1024 * 1024 ))

check() { backup::_check_space "$@" 2>&1; }

@test "a backup that will not fit is refused" {
    backup::_estimate_bytes() { printf '%s' $(( 4 * GB )); }
    backup::_free_bytes()     { printf '%s' $(( 64 * MB )); }

    run check
    [ "$status" -eq 1 ]
}

@test "the refusal names all three numbers, not just the shortfall" {
    # "Not enough disk" without the figures leaves you guessing how much to free.
    backup::_estimate_bytes() { printf '%s' $(( 4 * GB )); }
    backup::_free_bytes()     { printf '%s' $(( 64 * MB )); }

    run check
    [[ $output == *'4.0GB'* ]] || { echo 'volume total missing'; return 1; }
    [[ $output == *'2.5GB'* ]] || { echo 'estimated need missing'; return 1; }
    [[ $output == *'64MB'*  ]] || { echo 'free space missing'; return 1; }
    [[ $output == *'TC_BACKUP_KEEP'* ]] || { echo 'no remedy offered'; return 1; }
}

@test "a backup that fits proceeds" {
    backup::_estimate_bytes() { printf '%s' $(( 4 * GB )); }
    backup::_free_bytes()     { printf '%s' $(( 40 * GB )); }
    run check
    [ "$status" -eq 0 ]
}

@test "space exactly equal to the requirement is enough" {
    # required = needed/2 + 512MB. At exactly that, refusing would be wrong.
    backup::_estimate_bytes() { printf '%s' $(( 4 * GB )); }
    backup::_free_bytes()     { printf '%s' $(( 4 * GB / 2 + 512 * MB )); }
    run check
    [ "$status" -eq 0 ]
}

@test "one byte short of the requirement is refused" {
    backup::_estimate_bytes() { printf '%s' $(( 4 * GB )); }
    backup::_free_bytes()     { printf '%s' $(( 4 * GB / 2 + 512 * MB - 1 )); }
    run check
    [ "$status" -eq 1 ]
}

@test "a disk it cannot measure does not block the backup" {
    # df failing is not evidence of a full disk. Refusing on no information would
    # make the guard the thing that stops you taking a backup.
    backup::_estimate_bytes() { printf '%s' $(( 4 * GB )); }
    backup::_free_bytes()     { printf ''; }
    run check
    [ "$status" -eq 0 ]
}

@test "a non-numeric df reading does not block the backup either" {
    backup::_estimate_bytes() { printf '%s' $(( 4 * GB )); }
    backup::_free_bytes()     { printf 'df: /backups: No such file or directory'; }
    run check
    [ "$status" -eq 0 ]
}

@test "headroom is required even when there is nothing to copy" {
    backup::_estimate_bytes() { printf '0'; }
    backup::_free_bytes()     { printf '%s' $(( 100 * MB )); }
    run check
    [ "$status" -eq 1 ]
}

@test "the estimate covers only the volumes it is given" {
    # The logical backup writes the data directory and the database, not the agent
    # caches. Charging it for all 29 volumes would refuse backups that would fit.
    docker() {
        case $1 in
            volume) return 0 ;;
            run)    printf '1048576\t/v\n'; return 0 ;;   # 1 GiB in KiB, per volume
        esac
        return 1
    }
    run backup::_estimate_bytes teamcity_datadir teamcity_pgdata
    [ "$output" = "$(( 2 * GB ))" ]
}

@test "the estimate falls back to every volume in the stack" {
    render::volume_names() { printf 'a\nb\nc\n'; }
    docker() {
        case $1 in
            volume) return 0 ;;
            run)    printf '1048576\t/v\n'; return 0 ;;
        esac
        return 1
    }
    run backup::_estimate_bytes
    [ "$output" = "$(( 3 * GB ))" ]
}

@test "a volume that no longer exists is skipped rather than counted as zero-sized" {
    docker() { [[ $1 == volume ]] && return 1; return 1; }
    run backup::_estimate_bytes teamcity_gone
    [ "$output" = '0' ]
}

@test "the cold backup checks space before it stops anything" {
    # Order is the whole point: this one takes the entire stack down to copy.
    run grep -A4 '^backup::_cold()' "$LIB/backup.sh"
    [[ $output == *'_check_space'* ]]
    [[ $output != *'stack::compose'* ]] || { echo 'touches the stack before checking'; return 1; }
}

@test "the logical backup checks space before it stops the server" {
    run grep -A12 '^backup::_logical()' "$LIB/backup.sh"
    [[ $output == *'_check_space'* ]] || { echo 'unguarded — it writes gigabytes and stops the server'; return 1; }
}

@test "the logical backup is sized on what it writes, not on the whole stack" {
    run grep -A12 '^backup::_logical()' "$LIB/backup.sh"
    [[ $output == *'_check_space "$(conf::volume datadir)" "$(conf::volume pgdata)"'* ]]
}

@test "the native backup is left unguarded on purpose, and it says so" {
    run grep -A8 '^backup::_native()' "$LIB/backup.sh"
    [[ $output != *'_check_space'* ]]

    # A deliberate omission needs to read as one, or the next person "fixes" it
    # and breaks the backup you take when disk is short.
    run grep -B14 'backup::_free_bytes()' "$LIB/backup.sh"
    [[ $output == *'native backup is deliberately'* ]]
}
