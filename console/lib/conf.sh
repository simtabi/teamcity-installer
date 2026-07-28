#!/usr/bin/env bash
#
# conf.sh — stack configuration: where it lives, how it loads, how it saves.
#
# stack/.env      compose-visible settings. Everything here is interpolated into
#                 the rendered compose file and printed by `docker compose config`.
# stack/.secrets  the REST access token. Deliberately NOT in .env: anything in
#                 .env shows up in `docker compose config` output and in any
#                 diagnostics bundle built from it.

TC_ROOT=${TC_ROOT:-$PWD}
STACK_DIR="$TC_ROOT/stack"
ENV_FILE="$STACK_DIR/.env"
SECRETS_FILE="$STACK_DIR/.secrets"
COMPOSE_FILE="$STACK_DIR/docker-compose.yml"
LOCK_FILE="$STACK_DIR/.lock"
BACKUP_DIR="$TC_ROOT/backups"

# Defaults. The wizard overrides these; they double as the fallback when a value
# is missing from a partially hand-edited .env.
: "${TC_STACK:=teamcity}"
: "${TC_VERSION:=2026.1.3}"
: "${TC_PORT:=8111}"
: "${TC_DB:=postgres}"
: "${TC_PG_VERSION:=17}"
: "${TC_PG_DB:=teamcity}"
: "${TC_PG_USER:=teamcity}"
: "${TC_PG_PASSWORD:=}"
: "${TC_MEM_OPTS:=-Xmx2g -XX:ReservedCodeCacheSize=640m}"
: "${TC_AGENTS:=3}"
: "${TC_AGENT_IMAGE:=full}"
: "${TC_AGENT_DOCKER:=none}"
: "${TC_TZ:=${TZ:-UTC}}"
: "${TC_JDBC_VERSION:=42.7.13}"
: "${TC_AGENT_AUTO_AUTHORIZE:=0}"
: "${TC_AGENT_AUTH_TOKEN:=}"
: "${TC_ADMIN_USER:=admin}"
: "${TC_ADMIN_PASSWORD:=}"
: "${TC_BACKUP_KEEP:=5}"
: "${TC_LOG_LEVEL:=INFO}"

# The PostgreSQL JDBC driver TeamCity loads from <datadir>/lib/jdbc.
TC_JDBC_URL_BASE='https://repo1.maven.org/maven2/org/postgresql/postgresql'

EXAMPLE_FILE="$STACK_DIR/.env.example"

conf::exists() { [[ -f $ENV_FILE ]]; }

# Create stack/.env from the tracked example when it is missing.
#
# A fresh clone has no .env, and every command that needed one used to fail with
# "No stack configured". The example already documents every setting, so seeding
# from it means the only thing left to supply is a password — and the validator
# says so precisely rather than the command dying somewhere further in.
#
# Never overwrites an existing file.
conf::bootstrap() {
    conf::exists && return 0
    [[ -f $EXAMPLE_FILE ]] || return 1

    mkdir -p "$STACK_DIR"
    umask 077
    cp "$EXAMPLE_FILE" "$ENV_FILE"
    chmod 600 "$ENV_FILE"

    # A generated password beats leaving the example's empty one in place: the
    # stack cannot start without it, and nobody benefits from being asked for a
    # random string they will never type again.
    local generated; generated=$(validate::gen_password)
    conf::load
    TC_PG_PASSWORD=$generated
    conf::save

    ui::info "Created $ENV_FILE from the example, with a generated database password."
    log::info console.config 'bootstrapped stack/.env from stack/.env.example'
    return 0
}

# Validate everything before a command acts on it.
#
# Values were only checked when the compose file was rendered, so a command that
# did not render — status, logs, token, doctor — would run against a broken
# configuration and fail somewhere less obvious. Checking up front means the
# failure names the setting.
conf::validate() {
    conf::exists || return 0

    local ok=0
    validate::stack_name "$TC_STACK"  || ok=1
    validate::timezone   "$TC_TZ"     || ok=1
    validate::mem_opts   "$TC_MEM_OPTS" || ok=1

    if [[ ! $TC_PORT =~ ^[0-9]+$ ]] || (( TC_PORT < 1024 || TC_PORT > 65535 )); then
        ui::err "TC_PORT is '$TC_PORT'; it must be a number between 1024 and 65535."
        ok=1
    fi

    if [[ ! $TC_AGENTS =~ ^[0-9]+$ ]]; then
        ui::err "TC_AGENTS is '$TC_AGENTS'; it must be a number."
        ok=1
    fi

    case $TC_DB in
        postgres)
            validate::db_identifier "$TC_PG_DB"   || ok=1
            validate::db_identifier "$TC_PG_USER" || ok=1
            if [[ -z $TC_PG_PASSWORD ]]; then
                ui::err 'TC_PG_PASSWORD is empty; the database cannot start without one.'
                ui::note "Generate one:  openssl rand -base64 64 | tr -dc 'A-Za-z0-9._-' | cut -c1-32"
                ok=1
            else
                validate::db_password "$TC_PG_PASSWORD" || ok=1
            fi ;;
        hsqldb) ;;
        *) ui::err "TC_DB is '$TC_DB'; it must be 'postgres' or 'hsqldb'."; ok=1 ;;
    esac

    case $TC_AGENT_IMAGE in full|minimal) ;; *)
        ui::err "TC_AGENT_IMAGE is '$TC_AGENT_IMAGE'; it must be 'full' or 'minimal'."; ok=1 ;;
    esac
    case $TC_AGENT_DOCKER in none|dind|socket) ;; *)
        ui::err "TC_AGENT_DOCKER is '$TC_AGENT_DOCKER'; it must be 'none', 'dind' or 'socket'."; ok=1 ;;
    esac

    (( ok == 0 )) || {
        ui::blank
        ui::err 'stack/.env has values that would make this fail later.'
        ui::note "Fix them in $ENV_FILE, or delete it and run  ./tc install"
        return 1
    }
}

# Parsed, not sourced. Two reasons, both of which bit during development:
#
#  * bash and Compose read this file differently. `TC_MEM_OPTS=-Xmx2g -XX:...`
#    is one value to Compose, but to bash it is an assignment followed by a
#    command, so sourcing it tries to execute "-XX:ReservedCodeCacheSize=640m".
#  * sourcing a config file executes it. This one holds a password and is
#    explicitly documented as hand-editable; it should never be able to run.
#
# Values are written single-quoted, which Compose strips and this understands.
conf::load() {
    conf::exists || return 1

    local line key value
    while IFS= read -r line || [[ -n $line ]]; do
        [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
        [[ $line == *=* ]] || continue

        key=${line%%=*}
        value=${line#*=}
        key=${key//[[:space:]]/}

        [[ $key =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue

        # Strip one layer of matching surrounding quotes.
        if [[ ${#value} -ge 2 ]] && { [[ $value == \'*\' ]] || [[ $value == \"*\" ]]; }; then
            value=${value:1:${#value}-2}
        fi

        printf -v "$key" '%s' "$value"
        export "${key?}"
    done <"$ENV_FILE"
}

# Single-quote a value for the .env file, escaping any embedded single quote.
conf::_quote() {
    local v=${1//\'/\'\\\'\'}
    printf "'%s'" "$v"
}

conf::save() {
    mkdir -p "$STACK_DIR"
    umask 077

    # The section order and comments here are mirrored by stack/.env.example, and
    # a test asserts the two carry the same keys in the same order. Change one,
    # change the other.
    cat >"$ENV_FILE" <<EOF
# TeamCity Installer — stack configuration
#
# Generated by the setup wizard and rewritten whenever settings change, so
# comments you add here will not survive. Editing the values is supported: every
# one is re-validated when the compose file is rendered, and a bad value is
# rejected with a reason rather than silently applied.
#
# Values are single-quoted. Keep them that way — TC_MEM_OPTS contains spaces and
# would otherwise parse as two separate things.
#
# This file holds credentials and is gitignored. The tracked stack/.env.example
# documents the same settings with placeholders.

# --- identity -----------------------------------------------------------------
# TC_STACK names the Compose project, so every container, volume and network is
# prefixed with it. Renaming does not move data; the old volumes stay behind.

TC_STACK=$(conf::_quote "$TC_STACK")
TC_VERSION=$(conf::_quote "$TC_VERSION")
TC_PORT=$(conf::_quote "$TC_PORT")
TC_TZ=$(conf::_quote "$TC_TZ")

# --- database -----------------------------------------------------------------
# TC_DB is 'postgres' for a dedicated container, or 'hsqldb' for TeamCity's
# bundled database, which JetBrains support for evaluation only.
#
# The password cannot contain \$ \` " ' or a backslash: those break .env
# interpolation and the JDBC URL. Minimum 16 characters.

TC_DB=$(conf::_quote "$TC_DB")
TC_PG_VERSION=$(conf::_quote "$TC_PG_VERSION")
TC_PG_DB=$(conf::_quote "$TC_PG_DB")
TC_PG_USER=$(conf::_quote "$TC_PG_USER")
TC_PG_PASSWORD=$(conf::_quote "$TC_PG_PASSWORD")
TC_JDBC_VERSION=$(conf::_quote "$TC_JDBC_VERSION")

# --- build agents -------------------------------------------------------------
# Three agents is what TeamCity's free Professional licence covers; above that
# the server pauses the entire build queue.
#
# TC_AGENT_IMAGE is 'full' or 'minimal'. TC_AGENT_DOCKER is 'none', 'dind' or
# 'socket' — either Docker mode forces the full image, since the minimal one has
# no docker binary at all.

TC_AGENTS=$(conf::_quote "$TC_AGENTS")
TC_AGENT_IMAGE=$(conf::_quote "$TC_AGENT_IMAGE")
TC_AGENT_DOCKER=$(conf::_quote "$TC_AGENT_DOCKER")

# --- first administrator ------------------------------------------------------
# Created automatically the first time the server comes up with no accounts.
# Leave the password empty and one is generated and shown once, rather than kept
# on disk where it would go stale as soon as it changed in the UI. Set it only
# when a known value is needed, as CI would.

TC_ADMIN_USER=$(conf::_quote "$TC_ADMIN_USER")
TC_ADMIN_PASSWORD=$(conf::_quote "$TC_ADMIN_PASSWORD")

# --- resources ----------------------------------------------------------------
# The whole JVM options string is validated, not just -Xmx. Minimum 1g.

TC_MEM_OPTS=$(conf::_quote "$TC_MEM_OPTS")

# --- housekeeping -------------------------------------------------------------
# TC_BACKUP_KEEP bounds the archives in backups/, pruned oldest-first after each
# successful backup. TC_LOG_LEVEL is DEBUG, INFO, WARN, ERROR or OFF.

TC_BACKUP_KEEP=$(conf::_quote "$TC_BACKUP_KEEP")
TC_LOG_LEVEL=$(conf::_quote "$TC_LOG_LEVEL")

# --- compose ------------------------------------------------------------------
# Read directly by Docker Compose. Keep it equal to TC_STACK.

COMPOSE_PROJECT_NAME=$(conf::_quote "$TC_STACK")
EOF
    chmod 600 "$ENV_FILE"
}

# --- secrets ------------------------------------------------------------------

conf::token() {
    [[ -f $SECRETS_FILE ]] || return 1
    # shellcheck disable=SC1090
    source "$SECRETS_FILE"
    [[ -n ${TC_TOKEN:-} ]] || return 1
    printf '%s' "$TC_TOKEN"
}

conf::save_token() {
    mkdir -p "$STACK_DIR"
    umask 077
    printf 'TC_TOKEN=%s\n' "$1" >"$SECRETS_FILE"
    chmod 600 "$SECRETS_FILE"
}

conf::clear_token() { rm -f "$SECRETS_FILE"; }

# --- derived ------------------------------------------------------------------

conf::url()        { printf 'http://localhost:%s' "$TC_PORT"; }
conf::volume()     { printf '%s_%s' "$TC_STACK" "$1"; }
conf::agent_tag()  {
    # The minimal image contains no Docker at all, so *either* Docker mode
    # implies the full image. Honouring "minimal" alongside socket mode mounted
    # the daemon socket into a container with no `docker` binary: nothing errors,
    # and Docker builds simply never work.
    if [[ $TC_AGENT_DOCKER == dind ]]; then
        printf 'jetbrains/teamcity-agent:%s-linux-sudo' "$TC_VERSION"
    elif [[ $TC_AGENT_DOCKER == socket ]]; then
        printf 'jetbrains/teamcity-agent:%s' "$TC_VERSION"
    elif [[ $TC_AGENT_IMAGE == minimal ]]; then
        printf 'jetbrains/teamcity-minimal-agent:%s' "$TC_VERSION"
    else
        printf 'jetbrains/teamcity-agent:%s' "$TC_VERSION"
    fi
}

# --- locking ------------------------------------------------------------------
#
# Two ./tc invocations must not interleave a re-render with an `up`.
# Callers pair this with `trap conf::unlock RETURN` so the lock is released on
# every exit path, including failures. Without that the menu — one long-lived
# process — kept the lock for the rest of the session after any error, and a
# second ./tc in another terminal blocked on it with a misleading message.
TC_LOCK_HELD=0

conf::lock() {
    mkdir -p "$STACK_DIR"
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        ui::info 'Another ./tc is holding the stack lock; waiting…'
        flock 9
    fi
    TC_LOCK_HELD=1
}

# Guarded by a flag because a RETURN trap does not stay confined to the function
# that set it: bash restores the previous trap when the *handler* returns, so the
# trap survives into the caller's frame and fires again when the caller returns.
# Unguarded, that second firing would release a lock some later operation had
# legitimately taken. With the flag, the extra firing is a no-op.
conf::unlock() {
    (( TC_LOCK_HELD )) || return 0
    TC_LOCK_HELD=0
    exec 9>&- 2>/dev/null || true
}
