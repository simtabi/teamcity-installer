#!/usr/bin/env bats
#
# Host portability.
#
# console/lib runs in Alpine with GNU coreutils and is portable by construction.
# All the risk is in ./tc, which runs on whatever the user has: macOS, a Linux
# distribution, or WSL. These assert the launcher stays free of tools and flags
# that are not present everywhere.

load helper

# The library lives at /app/lib in the image, but the project itself is bind
# mounted at its host path, which the launcher passes as TC_ROOT. The launcher
# under test is therefore $TC_ROOT/tc, not a path relative to the test file.
setup() {
    PROJECT="${TC_ROOT:?TC_ROOT must be set — run through ./tc}"
    TC="$PROJECT/tc"
    [ -f "$TC" ] || skip "launcher not reachable at $TC"
}

@test "the launcher parses under POSIX sh" {
    run sh -n "$TC"
    [ "$status" -eq 0 ]
}

@test "the launcher parses under busybox ash" {
    run busybox sh -n "$TC"
    [ "$status" -eq 0 ]
}

@test "no bare shasum — it is a Perl script and Linux may not have Perl" {
    # Allowed only inside the fallback chain, which tries alternatives first.
    run grep -nE '^\s*(shasum|.*\| *shasum)' "$TC"
    [ "$status" -ne 0 ]
}

@test "the hashing fallback covers macOS and Linux" {
    grep -q 'sha256sum' "$TC"
    grep -q 'shasum'    "$TC"
    grep -q 'cksum'     "$TC"
}

@test "no sort -z — busybox sort does not support it" {
    # Comments may name it; only executable lines matter.
    run grep -nE '^[^#]*sort -z' "$TC"
    [ "$status" -ne 0 ]
}

@test "no GNU-only flags that BSD userland lacks" {
    for pattern in 'readlink -f' 'sed -i ' 'date -d ' 'stat -c' 'head -n -' 'du --exclude'; do
        run grep -nE "^[^#]*$(printf '%s' "$pattern" | sed 's/[][\.*^$]/\\&/g')" "$TC"
        [ "$status" -ne 0 ] || { echo "found GNU-only usage: $pattern"; return 1; }
    done
}

@test "timezone detection has a source for each platform" {
    grep -q 'TZ:-'          "$TC"   # user override
    grep -q '/etc/timezone' "$TC"   # Debian, most WSL
    grep -q '/etc/localtime' "$TC"  # macOS, systemd Linux
}

@test "the docker socket is resolved, never hardcoded as the only option" {
    grep -q 'docker context inspect' "$TC"
    grep -q 'DOCKER_HOST'            "$TC"
}

@test "WSL users are warned about the slow /mnt path" {
    grep -q '/mnt/' "$TC"
}

@test "line endings are pinned so a Windows checkout cannot break the shebang" {
    local attrs="$PROJECT/.gitattributes"
    [ -f "$attrs" ]
    grep -q 'eol=lf' "$attrs"
}

@test "no script in the project carries CRLF line endings" {
    local root="$PROJECT"
    local f bad=''
    for f in "$root"/tc "$root"/console/lib/*.sh "$root"/stack/init/*.sh; do
        [ -f "$f" ] || continue
        grep -qU $'\r' "$f" 2>/dev/null && bad+="$f "
    done
    [ -z "$bad" ] || { echo "CRLF found in: $bad"; return 1; }
}
