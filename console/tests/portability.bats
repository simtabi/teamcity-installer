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

# --- the hash becomes an image tag ---------------------------------------------
#
# The hashers disagree about their output format, and the launcher truncates to
# twelve characters without looking. sha256sum prints "<hex>  -"; cksum prints
# "<checksum> <bytes>", and its checksum is short enough that the space lands
# inside those twelve — "363105736 13", which docker build rejects outright with
# `invalid reference format`. cksum is the last resort, reached only where none
# of the others exist, so this was invisible on any machine that had them.

# The launcher's own two functions, extracted verbatim so nothing is reimplemented.
_hasher_probe() {
    local only=$1 dir="$BATS_TEST_TMPDIR/probe"
    mkdir -p "$dir/console"
    printf 'contents\n' > "$dir/console/file.txt"

    {
        sed -n '/^hash_stdin()/,/^}/p' "$TC"
        sed -n '/^console_hash()/,/^}/p' "$TC"
        printf 'ROOT=%s\nconsole_hash\n' "$dir"
    } > "$dir/probe.sh"

    # Hide every hasher but the one under test, by shadowing PATH.
    mkdir -p "$dir/bin"
    local real; real=$(command -v "$only") || skip "$only not available"
    ln -sf "$real" "$dir/bin/$only"
    for t in sh cat cut find sort tr sed; do
        real=$(command -v "$t") && ln -sf "$real" "$dir/bin/$t"
    done

    PATH="$dir/bin" sh "$dir/probe.sh"
}

@test "every hasher yields a tag docker will accept" {
    local h
    for h in sha256sum sha1sum md5sum cksum; do
        local out; out=$(_hasher_probe "$h")
        [[ $out =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
            || { echo "$h produced '$out', which is not a valid image tag"; return 1; }
    done
}

@test "cksum in particular does not smuggle a space into the tag" {
    local out; out=$(_hasher_probe cksum)
    [[ $out != *' '* ]] || { echo "cksum produced '$out'"; return 1; }
    [ -n "$out" ]
}

@test "every hasher yields the same tag twice for the same input" {
    local h first
    for h in sha256sum sha1sum md5sum cksum; do
        first=$(_hasher_probe "$h")
        # Non-empty first: two identical failures would otherwise read as stable.
        [ -n "$first" ] || { echo "$h produced nothing"; return 1; }
        [ "$first" = "$(_hasher_probe "$h")" ] || { echo "$h is not stable"; return 1; }
    done
}

@test "the hash is reduced to alphanumerics before it is truncated" {
    # Order matters: truncating first and cleaning after would still let a space
    # decide where the twelve characters end.
    run grep -A3 'hash_stdin \\' "$TC"
    [[ $output == *"tr -dc '[:alnum:]'"* ]]
}

# --- the WSL timezone shape -----------------------------------------------------

@test "the timezone falls to /etc/timezone when localtime is not a symlink" {
    # WSL copies /etc/localtime instead of symlinking it, so the readlink route
    # alone silently yields UTC and every build timestamp is wrong.
    run grep -A14 '^host_tz()' "$TC"
    [[ $output == *'/etc/timezone'* ]]
    # And it must be tried before the symlink, not after.
    local tz_line link_line
    tz_line=$(grep -n '/etc/timezone' "$TC" | head -1 | cut -d: -f1)
    link_line=$(grep -n 'readlink /etc/localtime' "$TC" | head -1 | cut -d: -f1)
    (( tz_line < link_line )) || { echo 'the symlink is consulted first'; return 1; }
}

@test "a Windows-drive checkout is called out before anything slow happens" {
    run grep -B2 -A6 '/mnt/\[a-z\]/\*' "$TC"
    [[ $output == *'Windows drive'* ]]
    # Before the docker lookup, so it is seen even when the setup is incomplete.
    local mnt_line docker_line
    mnt_line=$(grep -n '/mnt/\[a-z\]/\*' "$TC" | head -1 | cut -d: -f1)
    docker_line=$(grep -n "command -v docker" "$TC" | head -1 | cut -d: -f1)
    (( mnt_line < docker_line ))
}
