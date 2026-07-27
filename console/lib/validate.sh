#!/usr/bin/env bash
#
# validate.sh — input validators.
#
# Each takes a candidate, prints a specific objection to stderr when it rejects,
# and returns non-zero. "Invalid input" tells the user nothing; "port 80 needs
# root and TeamCity runs as uid 1000" tells them what to do instead.
#
# These run twice: once at the prompt, and again at render time. The second pass
# is what stops a hand-edited stack/.env from producing a broken compose file.

# --- helpers ------------------------------------------------------------------

validate::_reject() { ui::err "$*"; return 1; }

# Docker VM facts, cached — `docker info` is not cheap.
validate::_docker_ncpu() {
    [[ -n ${_TC_NCPU:-} ]] || _TC_NCPU=$(docker info --format '{{.NCPU}}' 2>/dev/null || echo 0)
    printf '%s' "$_TC_NCPU"
}

validate::_docker_mem_bytes() {
    [[ -n ${_TC_MEM:-} ]] || _TC_MEM=$(docker info --format '{{.MemTotal}}' 2>/dev/null || echo 0)
    printf '%s' "$_TC_MEM"
}

# --- ports --------------------------------------------------------------------

# Rejects a port that is unusable, and separately warns about one that is merely
# occupied. Two independent checks are needed: `docker ps` sees containers, and
# probing host.docker.internal sees everything else on the host.
validate::port() {
    local port=$1

    [[ $port =~ ^[0-9]+$ ]] \
        || validate::_reject "'$port' is not a number." || return 1

    (( port >= 1024 )) \
        || validate::_reject "Port $port is privileged. TeamCity runs as uid 1000 inside the container and cannot bind below 1024 — pick something ≥ 1024." || return 1

    (( port <= 65535 )) \
        || validate::_reject "Port $port is above the maximum of 65535." || return 1

    local holder
    holder=$(docker ps --format '{{.Names}} {{.Ports}}' 2>/dev/null \
        | grep -E "(^|[^0-9:])(0\.0\.0\.0|\[::\]|127\.0\.0\.1):$port->" \
        | awk '{print $1}' | head -1 || true)

    if [[ -n $holder ]]; then
        # Our own running stack holding the port is not a conflict. Without this
        # every restart fails validation, because the server it is about to
        # recreate is still publishing the port it is being asked to use.
        # Compose names containers <project>-<service>-<index>.
        if [[ $holder == "$TC_STACK"-* ]]; then
            return 0
        fi
        validate::_reject "Port $port is already published by container '$holder'."
        return 1
    fi

    if validate::_host_port_listening "$port"; then
        validate::_reject "Port $port is already in use by something on the host (not a container)."
        return 1
    fi

    return 0
}

validate::_host_port_listening() {
    local port=$1
    # `nc` is not in the console image; bash's /dev/tcp is, and is enough.
    timeout 1 bash -c "exec 3<>/dev/tcp/host.docker.internal/$port" 2>/dev/null
}

# Suggests the first free port at or after $1.
validate::next_free_port() {
    local port=$1 limit=$(( $1 + 200 ))
    while (( port < limit )); do
        if ! validate::_host_port_listening "$port"; then printf '%s' "$port"; return 0; fi
        port=$(( port + 1 ))
    done
    printf '%s' "$1"
}

# --- names --------------------------------------------------------------------

validate::stack_name() {
    local name=$1

    [[ $name =~ ^[a-z][a-z0-9-]{1,30}$ ]] \
        || validate::_reject "Stack names must be 2–31 characters, start with a lowercase letter, and contain only lowercase letters, digits and hyphens. Docker derives volume, network and container names from this." || return 1

    return 0
}

validate::agent_name() {
    local name=$1
    [[ $name =~ ^[A-Za-z0-9._-]{1,60}$ ]] \
        || validate::_reject "Agent names may contain only letters, digits, dot, underscore and hyphen, up to 60 characters." || return 1
    return 0
}

# --- agents -------------------------------------------------------------------

# The free Professional licence covers three agents and TeamCity ships with all
# three authorized. Going past three does not degrade gracefully: the server
# pauses the whole build queue, which reads as a hang rather than a licence
# problem. So four or more requires deliberate opt-in.
TC_FREE_AGENTS=3

validate::agent_count() {
    local count=$1

    [[ $count =~ ^[0-9]+$ ]] \
        || validate::_reject "'$count' is not a number." || return 1

    (( count <= 32 )) \
        || validate::_reject "$count agents is beyond anything this tool will render." || return 1

    if (( count > TC_FREE_AGENTS )); then
        if [[ ${TC_ALLOW_EXTRA_AGENTS:-0} != 1 ]]; then
            ui::warn "The free Professional licence covers $TC_FREE_AGENTS agents."
            ui::note "Above $TC_FREE_AGENTS, TeamCity pauses the entire build queue until you"
            ui::note "drop back to the licensed count — it looks like a hang, not a licence error."
            ui::note "Set a licence in the UI first, then re-run with more agents."
            return 1
        fi
        ui::warn "Rendering $count agents. The build queue will pause unless a licence covers them."
    fi

    local ncpu; ncpu=$(validate::_docker_ncpu)
    if (( ncpu > 0 && count > ncpu / 2 )); then
        ui::warn "$count agents on a $ncpu-CPU Docker VM will contend heavily."
    fi

    return 0
}

# --- memory -------------------------------------------------------------------

# Validates the whole JVM options string, not just -Xmx. The image default is
#   -Xmx2g -XX:ReservedCodeCacheSize=640m
# and a regex that only understood -Xmx would silently discard the code cache
# setting the moment anyone edited the value.
validate::mem_opts() {
    local opts=$1

    [[ -n $opts ]] \
        || validate::_reject 'Memory options cannot be empty.' || return 1

    # The pattern lives in a variable because it contains a space: an unquoted
    # regex operand to [[ =~ ]] is split on whitespace, which would make this a
    # syntax error rather than the check it looks like.
    local allowed='^[-A-Za-z0-9:=+. ]+$'
    [[ $opts =~ $allowed ]] \
        || validate::_reject 'Memory options may contain only JVM flag characters.' || return 1

    [[ $opts == *-Xmx* ]] \
        || validate::_reject 'Memory options must include an -Xmx value, for example: -Xmx2g -XX:ReservedCodeCacheSize=640m' || return 1

    local xmx unit size bytes
    xmx=$(printf '%s' "$opts" | grep -oE '\-Xmx[0-9]+[kKmMgG]?' | head -1)
    size=$(printf '%s' "$xmx" | grep -oE '[0-9]+')
    unit=${xmx##*[0-9]}

    case ${unit,,} in
        g) bytes=$(( size * 1024 * 1024 * 1024 )) ;;
        m) bytes=$(( size * 1024 * 1024 )) ;;
        k) bytes=$(( size * 1024 )) ;;
        *) bytes=$size ;;
    esac

    if (( bytes < 1024 * 1024 * 1024 )); then
        validate::_reject "-Xmx is $xmx. TeamCity needs at least 1g and will fail to start below it."
        return 1
    fi

    local vm; vm=$(validate::_docker_mem_bytes)
    if (( vm > 0 && bytes > vm * 70 / 100 )); then
        ui::warn "$xmx is more than 70% of the Docker VM's $(numfmt --to=iec "$vm")B."
        ui::note 'The database and agents also need headroom. Raise the VM memory or lower -Xmx.'
    fi

    return 0
}

# --- database -----------------------------------------------------------------

# The excluded characters are not paranoia: $ triggers Compose interpolation,
# and quotes and backslashes break either the .env parse or the JDBC URL.
validate::db_password() {
    local pw=$1

    (( ${#pw} >= 16 )) \
        || validate::_reject "Password is ${#pw} characters; use at least 16." || return 1

    # case, not a glob in [[ ]]: the character class needs both quote kinds and a
    # backslash, which is unreadable and easy to get wrong inline.
    case $pw in
        *'$'* | *'"'* | *"'"* | *\\* | *'`'*)
            validate::_reject 'Password cannot contain $, backtick, quotes or backslashes — they break .env interpolation and the JDBC URL.'
            return 1 ;;
    esac

    local printable='^[[:print:]]+$'
    [[ $pw =~ $printable ]] \
        || validate::_reject 'Password must be printable ASCII.' || return 1

    return 0
}

validate::db_identifier() {
    local id=$1
    [[ $id =~ ^[a-z_][a-z0-9_]{0,62}$ ]] \
        || validate::_reject "'$id' is not a valid PostgreSQL identifier (lowercase letters, digits and underscore; must not start with a digit)." || return 1
    return 0
}

validate::gen_password() {
    # Allow-list rather than deny-list: keep only characters that are safe in a
    # .env value and a JDBC URL, so this can never emit something db_password
    # would then reject.
    openssl rand -base64 64 | tr -dc 'A-Za-z0-9._-' | cut -c1-32
}

# --- version ------------------------------------------------------------------

TC_HUB_SERVER='https://hub.docker.com/v2/repositories/jetbrains/teamcity-server/tags'

# 0 = tag exists with an image for $arch
# 1 = no such tag
# 2 = tag exists but publishes no image for $arch
# 3 = could not reach Docker Hub
#
# `curl -f` is deliberately not used here: it collapses "404, no such tag" and
# "the network is down" into the same non-zero exit, which made a typo'd version
# report as an offline warning and sail through.
validate::_tag_has_arch() {
    local tag=$1 arch=$2 response code body
    response=$(curl -sS --max-time 10 -w $'\n%{http_code}' "$TC_HUB_SERVER/$tag" 2>/dev/null) || return 3

    code=${response##*$'\n'}
    body=${response%$'\n'*}

    case $code in
        200) ;;
        404) return 1 ;;
        *)   return 3 ;;
    esac

    printf '%s' "$body" | jq -e --arg a "$arch" \
        '[.images[]? | select(.architecture == $a)] | length > 0' >/dev/null 2>&1 && return 0
    return 2
}

validate::tc_version() {
    local version=$1
    local arch; arch=$(docker version --format '{{.Server.Arch}}' 2>/dev/null || echo amd64)

    [[ $version =~ ^[0-9]{4}\.[0-9]+(\.[0-9]+)?$ ]] \
        || validate::_reject "'$version' does not look like a TeamCity version (expected e.g. 2026.1.3)." || return 1

    local rc; validate::_tag_has_arch "$version" "$arch"; rc=$?

    case $rc in
        0) return 0 ;;
        1)  validate::_reject "There is no jetbrains/teamcity-server:$version on Docker Hub."
            return 1 ;;
        2)  validate::_reject "jetbrains/teamcity-server:$version publishes no $arch image, so it cannot run natively on this machine."
            return 1 ;;
        *)  # Genuinely unreachable. Do not block an install on a network blip.
            ui::warn "Could not reach Docker Hub to verify tag '$version'."
            ui::note 'Accepting it unverified. If it does not exist, the pull will fail with a clear error.'
            return 0 ;;
    esac
}

# Lists versions that have an image for the running architecture, newest first.
validate::available_versions() {
    local arch; arch=$(docker version --format '{{.Server.Arch}}' 2>/dev/null || echo amd64)
    curl -fsS --max-time 15 "$TC_HUB_SERVER?page_size=100" 2>/dev/null \
        | jq -r --arg a "$arch" '
            .results[]
            | select(.name | test("^[0-9]{4}\\.[0-9]+(\\.[0-9]+)?$"))
            | select([.images[]? | select(.architecture == $a)] | length > 0)
            | .name
          ' 2>/dev/null \
        | sort -Vr
}

# --- tokens -------------------------------------------------------------------

validate::rest_token() {
    local token=$1

    [[ $token =~ ^[A-Za-z0-9._~+/-]{20,}$ ]] \
        || validate::_reject 'That does not look like a TeamCity access token (expected 20+ token characters). Generate one under Your Profile → Access Tokens.' || return 1

    return 0
}

# --- timezone -----------------------------------------------------------------

validate::timezone() {
    local tz=$1
    [[ -f /usr/share/zoneinfo/$tz ]] \
        || validate::_reject "'$tz' is not a zone in the tz database (expected e.g. Europe/Berlin or UTC)." || return 1
    return 0
}
