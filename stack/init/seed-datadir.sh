#!/bin/sh
#
# seed-datadir.sh — prepare the TeamCity data directory for PostgreSQL.
#
# Runs once, before the server starts. It puts two things in place that TeamCity
# otherwise asks for interactively on first launch:
#
#   <datadir>/lib/jdbc/postgresql-*.jar   the driver
#   <datadir>/config/database.properties  the connection
#
# With both present the first-run web wizard skips the database step entirely
# and goes straight to the licence agreement and admin account. That is the
# difference between "automated" and "automated except the fiddly part".
#
# Idempotent: if database.properties already exists it changes nothing, so a
# restart never clobbers a configuration the user has since edited by hand.

set -eu

DATADIR='/data/teamcity_server/datadir'
CACHE='/cache'
JDBC_DIR="$DATADIR/lib/jdbc"
CONFIG_DIR="$DATADIR/config"
PROPS="$CONFIG_DIR/database.properties"
JAR="postgresql-${TC_JDBC_VERSION}.jar"
MAVEN="https://repo1.maven.org/maven2/org/postgresql/postgresql/${TC_JDBC_VERSION}/${JAR}"

log() { printf '[seed-datadir] %s\n' "$1"; }

TC_UID=1000   # tcuser in jetbrains/teamcity-server
TC_GID=1000

if [ "$(id -u)" != '0' ]; then
    log "FATAL: must run as root to seed a fresh volume (running as $(id -u))."
    exit 1
fi

mkdir -p "$JDBC_DIR" "$CONFIG_DIR"

# --- agent auto-authorization --------------------------------------------------
#
# A server-side internal property; an agent presenting the same value in its
# buildAgent.properties (the image exposes that as AGENT_TOKEN) is authorized on
# connect. This removes the one step every other TeamCity-in-Docker setup leaves
# manual — agents otherwise appear as "Unauthorized" and silently take no builds.
#
# It bypasses a step that is normally behind TeamCity authentication, so it suits
# a localhost-bound stack and not a server exposed to the internet. Set
# TC_AGENT_AUTO_AUTHORIZE=0 to turn it off.

INTERNAL="$CONFIG_DIR/internal.properties"

if [ -n "${TC_AGENT_AUTH_TOKEN:-}" ]; then
    if [ -f "$INTERNAL" ] && grep -q '^teamcity.agentAutoAuthorize.authorizationToken=' "$INTERNAL"; then
        log 'agent auto-authorization already configured'
    else
        log 'enabling agent auto-authorization'
        touch "$INTERNAL"
        # Drop any stale value before appending, so re-running is idempotent.
        grep -v '^teamcity.agentAutoAuthorize.authorizationToken=' "$INTERNAL" > "$INTERNAL.tmp" 2>/dev/null || true
        mv -f "$INTERNAL.tmp" "$INTERNAL" 2>/dev/null || true
        printf 'teamcity.agentAutoAuthorize.authorizationToken=%s\n' "$TC_AGENT_AUTH_TOKEN" >> "$INTERNAL"
        chmod 600 "$INTERNAL"
    fi
else
    log 'agent auto-authorization disabled'
fi

# Everything below configures PostgreSQL; the bundled database needs none of it.
if [ "${TC_DB:-postgres}" != 'postgres' ]; then
    log "database mode is ${TC_DB:-postgres}, skipping JDBC and database.properties"
    chown -R "$TC_UID:$TC_GID" "$DATADIR"
    log 'data directory ready'
    exit 0
fi

# --- driver -------------------------------------------------------------------

if [ -f "$JDBC_DIR/$JAR" ]; then
    log "driver already present: $JAR"
elif [ -f "$CACHE/$JAR" ]; then
    log "driver from cache: $JAR"
    cp "$CACHE/$JAR" "$JDBC_DIR/$JAR"
else
    log "downloading $JAR"
    apk add --no-cache curl >/dev/null 2>&1 || true

    if curl -fsSL --max-time 120 -o "$CACHE/$JAR.part" "$MAVEN"; then
        # Maven publishes a .sha1 next to every artifact. Verifying it costs one
        # request and turns a truncated download into a clear failure instead of
        # a ClassNotFoundException at server start.
        expected=$(curl -fsSL --max-time 30 "$MAVEN.sha1" 2>/dev/null | tr -d '[:space:]' || true)
        actual=$(sha1sum "$CACHE/$JAR.part" | cut -d' ' -f1)

        if [ -n "$expected" ] && [ "$expected" != "$actual" ]; then
            rm -f "$CACHE/$JAR.part"
            log "FATAL: checksum mismatch (expected $expected, got $actual)"
            exit 1
        fi

        mv "$CACHE/$JAR.part" "$CACHE/$JAR"
        cp "$CACHE/$JAR" "$JDBC_DIR/$JAR"
        log "driver installed and cached"
    else
        log "FATAL: could not download the PostgreSQL JDBC driver."
        log "TeamCity cannot reach PostgreSQL without it. Check network access to"
        log "repo1.maven.org, or switch the stack to the bundled database."
        exit 1
    fi
fi

# Stale drivers on the classpath cause hard-to-read version conflicts; TeamCity's
# own documentation says to keep exactly one.
find "$JDBC_DIR" -name 'postgresql-*.jar' ! -name "$JAR" -exec rm -f {} + 2>/dev/null || true

# --- connection ---------------------------------------------------------------

if [ -f "$PROPS" ]; then
    log 'database.properties already exists, leaving it alone'
else
    log 'writing database.properties'
    cat >"$PROPS" <<EOF
# Written by the TeamCity control console on first start.
#
# 'db' is the database service on the compose network. It is not published to
# the host, so this hostname only resolves from inside the stack.

connectionUrl=jdbc:postgresql://db:5432/${TC_PG_DB}
connectionProperties.user=${TC_PG_USER}
connectionProperties.password=${TC_PG_PASSWORD}

# Must stay below the database's max_connections (the stack sets it to 200).
maxConnections=50
EOF
    chmod 600 "$PROPS"
fi

# --- ownership ----------------------------------------------------------------
#
# The whole point of the root/chown ordering. The server runs as uid 1000 and
# writes throughout this tree; without this it starts, fails to write, and
# reports a permissions error that does not mention the data directory.

log "handing the data directory to ${TC_UID}:${TC_GID}"
chown -R "$TC_UID:$TC_GID" "$DATADIR"
chown -R "$TC_UID:$TC_GID" "$CACHE" 2>/dev/null || true

log 'data directory ready'
