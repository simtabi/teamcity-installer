#!/usr/bin/env bash
#
# preflight.sh — is this machine able to run the stack?
#
# Every row prints a remedy on failure. A checklist that only says "✗ memory" is
# a worse experience than no checklist at all.

PREFLIGHT_FAILURES=0
PREFLIGHT_WARNINGS=0

# Thin aliases over the shared helpers in ui.sh, so preflight and verify render
# identically and plain mode is handled in exactly one place.
preflight::_pass() { ui::row_pass "$1" "${2:-}"; }
preflight::_warn() { ui::row_warn "$1" "${2:-}"; PREFLIGHT_WARNINGS=$((PREFLIGHT_WARNINGS+1)); }
preflight::_fail() { ui::row_fail "$1" "${2:-}"; PREFLIGHT_FAILURES=$((PREFLIGHT_FAILURES+1)); }
preflight::_hint() { ui::hint "$1"; }

preflight::run() {
    PREFLIGHT_FAILURES=0
    PREFLIGHT_WARNINGS=0

    ui::head 'Preflight'

    preflight::_daemon
    preflight::_compose
    preflight::_arch
    preflight::_memory
    preflight::_disk
    preflight::_paths
    preflight::_ports

    ui::blank
    if (( PREFLIGHT_FAILURES > 0 )); then
        ui::err "$PREFLIGHT_FAILURES check(s) failed. Resolve them before installing."
        return 1
    fi
    if (( PREFLIGHT_WARNINGS > 0 )); then
        ui::warn "$PREFLIGHT_WARNINGS warning(s). The stack will run, but read them first."
        return 0
    fi
    ui::ok 'All checks passed.'
    return 0
}

preflight::_daemon() {
    if docker info >/dev/null 2>&1; then
        preflight::_pass 'Docker daemon' "$(docker version --format '{{.Server.Version}}' 2>/dev/null)"
    else
        preflight::_fail 'Docker daemon' 'unreachable'
        preflight::_hint 'Start OrbStack or Docker Desktop.'
    fi
}

preflight::_compose() {
    local v
    if v=$(docker compose version --short 2>/dev/null); then
        if [[ ${v%%.*} =~ ^[0-9]+$ ]] && (( ${v%%.*} >= 2 )); then
            preflight::_pass 'Compose plugin' "v$v"
        else
            preflight::_fail 'Compose plugin' "v$v is too old"
            preflight::_hint 'The rendered file uses the Compose v2 schema. Upgrade Docker.'
        fi
    else
        preflight::_fail 'Compose plugin' 'not available'
        preflight::_hint 'Install the docker compose plugin (bundled with OrbStack and Docker Desktop).'
    fi
}

preflight::_arch() {
    local host_arch image_arch
    host_arch=$(docker version --format '{{.Server.Arch}}' 2>/dev/null || echo unknown)

    if image_arch=$(docker image inspect "jetbrains/teamcity-server:$TC_VERSION" \
            --format '{{.Architecture}}' 2>/dev/null); then
        if [[ $image_arch == "$host_arch" ]]; then
            preflight::_pass 'Image architecture' "$image_arch, native"
        else
            preflight::_warn 'Image architecture' "image is $image_arch, host is $host_arch"
            preflight::_hint 'It will run under emulation — expect it to be several times slower.'
        fi
    else
        # Not pulled yet; check the registry instead of guessing.
        if validate::_tag_has_arch "$TC_VERSION" "$host_arch"; then
            preflight::_pass 'Image architecture' "$host_arch image published"
        else
            preflight::_warn 'Image architecture' "could not confirm a $host_arch image"
        fi
    fi
}

preflight::_memory() {
    local bytes; bytes=$(validate::_docker_mem_bytes)
    local gib=$(( bytes / 1024 / 1024 / 1024 ))

    if (( bytes == 0 )); then
        preflight::_warn 'Docker VM memory' 'unknown'
        return
    fi

    # Server -Xmx2g plus JVM overhead, Postgres, and agents.
    if (( gib >= 6 )); then
        preflight::_pass 'Docker VM memory' "${gib} GiB"
    elif (( gib >= 4 )); then
        preflight::_warn 'Docker VM memory' "${gib} GiB"
        preflight::_hint "Enough for the server and database, tight with $TC_AGENTS agents."
    else
        preflight::_fail 'Docker VM memory' "${gib} GiB"
        preflight::_hint 'TeamCity alone wants ~2 GiB heap. Raise the VM memory to at least 4 GiB.'
    fi
}

preflight::_disk() {
    local avail
    avail=$(df -PB1 /var/lib/docker 2>/dev/null | awk 'NR==2 {print $4}')
    [[ -n ${avail:-} ]] || avail=$(df -PB1 / 2>/dev/null | awk 'NR==2 {print $4}')

    if [[ -z ${avail:-} ]]; then
        preflight::_warn 'Free disk' 'unknown'
        return
    fi

    local gib=$(( avail / 1024 / 1024 / 1024 ))
    if (( gib >= 20 )); then
        preflight::_pass 'Free disk' "${gib} GiB"
    elif (( gib >= 10 )); then
        preflight::_warn 'Free disk' "${gib} GiB"
        preflight::_hint 'The images alone are ~2 GiB; build artifacts grow quickly.'
    else
        preflight::_fail 'Free disk' "${gib} GiB"
        preflight::_hint 'Free up space, or reclaim some with: docker system prune'
    fi
}

preflight::_paths() {
    if mkdir -p "$STACK_DIR" 2>/dev/null && [[ -w $STACK_DIR ]]; then
        preflight::_pass 'stack/ writable'
    else
        preflight::_fail 'stack/ writable' "$STACK_DIR"
        preflight::_hint 'The console needs to write the generated compose file and .env here.'
    fi

    if mkdir -p "$BACKUP_DIR" 2>/dev/null && [[ -w $BACKUP_DIR ]]; then
        preflight::_pass 'backups/ writable'
    else
        preflight::_fail 'backups/ writable' "$BACKUP_DIR"
    fi

    # The project is bind-mounted at its host path so backup containers can
    # write to it. If that mount did not survive, backups would silently land
    # inside the console container instead of on the host.
    if [[ -d $TC_ROOT ]]; then
        preflight::_pass 'Project mount' "$TC_ROOT"
    else
        preflight::_fail 'Project mount' "$TC_ROOT missing"
        preflight::_hint 'Run through ./tc rather than invoking the image directly.'
    fi
}

preflight::_ports() {
    if validate::_host_port_listening "$TC_PORT"; then
        # Ours, or someone else's?
        local holder
        holder=$(docker ps --format '{{.Names}} {{.Ports}}' 2>/dev/null \
            | grep -E ":$TC_PORT->" | awk '{print $1}' | head -1 || true)
        if [[ $holder == "$TC_STACK"* ]]; then
            preflight::_pass "Port $TC_PORT" "held by this stack ($holder)"
        elif [[ -n $holder ]]; then
            preflight::_fail "Port $TC_PORT" "taken by container '$holder'"
            preflight::_hint 'Stop that container or pick another port.'
        else
            preflight::_fail "Port $TC_PORT" 'taken by a host process'
            preflight::_hint "Free it, or re-run the wizard and choose $(validate::next_free_port "$TC_PORT")."
        fi
    else
        preflight::_pass "Port $TC_PORT" 'free'
    fi
}
