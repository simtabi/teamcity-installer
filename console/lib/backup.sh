#!/usr/bin/env bash
#
# backup.sh — backup and restore.
#
# Three tiers, because they fail in different ways:
#
#   native    TeamCity's own archive, taken through REST while running. Portable
#             across TeamCity versions and across database backends. The one
#             JetBrains support will ask for.
#   logical   pg_dump -Fc plus a tar of the data directory. Portable across
#             PostgreSQL major versions, which a raw PGDATA tar is not — that
#             matters the first time the stack moves from postgres:17 to 18.
#   cold      tar of every volume. Fastest and most complete, but tied to the
#             exact PostgreSQL major that wrote it.
#
# Every archive carries a manifest, and restore refuses combinations that would
# produce a server that will not start.

BACKUP_HELPER='alpine:3.22'

backup::menu() {
    ui::scope backup
    while true; do
        local choice
        choice=$(ui::menu 'Backup and restore' \
            "Back up|choose a method" \
            'Restore|replace the current stack from an archive' \
            'List|archives in backups/' \
            'Back|') || return 0

        case $choice in
            'Back up') backup::create; ui::pause 'Backup' ;;
            Restore)   backup::restore; ui::pause 'Restore' ;;
            List)      backup::list; ui::pause 'List' ;;
            Back)      return 0 ;;
        esac
    done
}

# --- helpers ------------------------------------------------------------------

# Timestamps come from the daemon, since the console has no host clock guarantee
# beyond the TZ it was handed.
backup::_stamp() { date +%Y%m%d-%H%M%S; }

backup::_dir() { printf '%s/%s' "$BACKUP_DIR" "$1"; }

# --- retention ----------------------------------------------------------------
#
# Archives are ~1 GB each and nothing pruned them, so a stack backed up weekly
# quietly consumed the disk. Oldest-first, and it names what it removes rather
# than deleting silently — a backup disappearing without a word is worse than
# one that never existed.
# Archive names carry no stack — they are all "teamcity-<kind>-<stamp>" whatever
# the stack is called — so retention has to read the manifest to know whose an
# archive is. It matters: a second stack sharing this checkout (a version test,
# a staging instance) would otherwise count its own backups against the limit and
# delete the first stack's, oldest-first, with a message naming files their owner
# never made.
#
# An archive that cannot be attributed at all is left alone and reported rather
# than deleted. Retention is worth less than a backup nobody can replace.
backup::_archive_stack() {
    [[ -f $1/manifest.json ]] || return 0
    jq -r '.stack // ""' "$1/manifest.json" 2>/dev/null
}

backup::prune() {
    local keep=${TC_BACKUP_KEEP:-5}
    [[ $keep =~ ^[0-9]+$ ]] || return 0
    (( keep > 0 )) || return 0

    local -a all archives=() foreign=()
    mapfile -t all < <(find "$BACKUP_DIR" -maxdepth 1 -mindepth 1 -type d -name 'teamcity-*' | sort)

    local d owner
    for d in "${all[@]}"; do
        owner=$(backup::_archive_stack "$d")
        if [[ $owner == "$TC_STACK" ]]; then archives+=("$d")
        else foreign+=("$d")
        fi
    done

    local excess=$(( ${#archives[@]} - keep ))
    if (( excess <= 0 )); then
        (( ${#foreign[@]} > 0 )) && log::debug backup.prune \
            "left ${#foreign[@]} archive(s) belonging to another stack alone"
        return 0
    fi

    ui::blank
    ui::info "Retention: keeping the newest $keep archive(s)."
    local i
    for (( i = 0; i < excess; i++ )); do
        ui::note "  removing $(basename "${archives[$i]}") ($(du -sh "${archives[$i]}" 2>/dev/null | cut -f1))"
        log::info backup.prune "removed $(basename "${archives[$i]}")"
        rm -rf "${archives[$i]}"
    done
    ui::ok "Pruned $excess old archive(s)."
    if (( ${#foreign[@]} > 0 )); then
        ui::note "  ${#foreign[@]} archive(s) are not this stack's and were left alone."
    fi
}

# --- disk guard ---------------------------------------------------------------
#
# A cold backup writes roughly the size of the volumes it copies. Filling the
# disk mid-backup takes the running stack down with it, so refuse up front and
# show both numbers rather than letting it fail halfway.
backup::_free_bytes() {
    df -Pk "$BACKUP_DIR" 2>/dev/null | awk 'NR==2 {print $4 * 1024}'
}

backup::_estimate_bytes() {
    local total=0 vol size
    while IFS= read -r vol; do
        docker volume inspect "$vol" >/dev/null 2>&1 || continue
        size=$(docker run --rm -v "$vol":/v:ro alpine:3.22 du -sk /v 2>/dev/null | awk '{print $1}')
        [[ $size =~ ^[0-9]+$ ]] && total=$(( total + size * 1024 ))
    done < <(render::volume_names)
    printf '%s' "$total"
}

backup::_check_space() {
    local needed free
    needed=$(backup::_estimate_bytes)
    free=$(backup::_free_bytes)

    [[ $free =~ ^[0-9]+$ ]] || return 0     # cannot tell; do not block

    # Compressed archives are smaller than the source, but leave real headroom.
    local required=$(( needed / 2 + 512 * 1024 * 1024 ))

    if (( free < required )); then
        ui::err 'Not enough free disk for this backup.'
        ui::note "  volumes total   $(numfmt --to=iec "$needed" 2>/dev/null || echo "$needed")B"
        ui::note "  estimated need  $(numfmt --to=iec "$required" 2>/dev/null || echo "$required")B (compressed, plus headroom)"
        ui::note "  free in backups/ $(numfmt --to=iec "$free" 2>/dev/null || echo "$free")B"
        ui::note 'Free space, or lower TC_BACKUP_KEEP and prune older archives first.'
        log::error backup.space "refused: need $required, free $free"
        return 1
    fi
    return 0
}

# Runs a helper container with a volume mounted read-only and the backup
# directory writable. The backup dir is addressed by its host path because the
# daemon, not the console, resolves bind mounts.
backup::_tar_volume() {
    local volume=$1 target=$2
    docker run --rm \
        --volume "$volume":/src:ro \
        --volume "$BACKUP_DIR":/out \
        "$BACKUP_HELPER" \
        tar czf "/out/$target" -C /src . 2>/dev/null
}

# Volumes are labelled as Compose's own when created here. Without the labels
# Compose prints "volume … already exists but was not created by Docker Compose"
# for every one of them — 29 warnings in the middle of a restore, none of them
# actionable.
backup::_create_volume() {
    local volume=$1
    docker volume inspect "$volume" >/dev/null 2>&1 && return 0
    docker volume create \
        --label com.docker.compose.project="$TC_STACK" \
        --label com.docker.compose.volume="${volume#"${TC_STACK}_"}" \
        --label com.docker.compose.version="$(docker compose version --short 2>/dev/null || echo 2)" \
        "$volume" >/dev/null 2>&1
}

backup::_untar_volume() {
    local volume=$1 archive=$2
    # Wipe first: untarring over existing content merges two states and produces
    # a data directory that matches neither.
    docker run --rm \
        --volume "$volume":/dst \
        --volume "$BACKUP_DIR":/in:ro \
        "$BACKUP_HELPER" \
        sh -c "find /dst -mindepth 1 -delete && tar xzf '/in/$archive' -C /dst" 2>/dev/null
}

backup::_pg_major() {
    stack::compose exec -T db psql -U "$TC_PG_USER" -d "$TC_PG_DB" -tAc 'SHOW server_version;' 2>/dev/null \
        | cut -d. -f1 | tr -d '[:space:]'
}

backup::_write_manifest() {
    local dir=$1 kind=$2 pg_major=$3
    shift 3
    local -a volumes=("$@")

    jq -n \
        --arg kind "$kind" \
        --arg stack "$TC_STACK" \
        --arg version "$TC_VERSION" \
        --arg db "$TC_DB" \
        --arg pg "$pg_major" \
        --arg tz "$TC_TZ" \
        --arg created "$(date -Iseconds)" \
        --argjson agents "$TC_AGENTS" \
        --args '{
            kind: $kind, stack: $stack, teamcity_version: $version,
            database: $db, postgres_major: $pg, timezone: $tz,
            agents: $agents, created: $created, volumes: $ARGS.positional
        }' "${volumes[@]}" >"$dir/manifest.json"

    # The rendered stack travels with the archive so a restore is self-describing.
    cp "$COMPOSE_FILE" "$dir/docker-compose.yml" 2>/dev/null || true

    # Two copies of the configuration, for two different readers.
    #
    # env.txt is redacted and meant for a human skimming what the archive holds.
    #
    # config.env is the real thing, because a restore has to be able to put the
    # configuration back. Redacting it bought nothing: the archive already
    # carries the same password in plaintext inside the data directory's
    # database.properties and inside the PostgreSQL volume. Withholding it from
    # the one file a restore could use made restores lossy without making the
    # archive any safer.
    sed -e 's/^TC_PG_PASSWORD=.*/TC_PG_PASSWORD=<redacted>/' \
        -e 's/^TC_ADMIN_PASSWORD=.*/TC_ADMIN_PASSWORD=<redacted>/' \
        "$ENV_FILE" >"$dir/env.txt" 2>/dev/null || true

    cp "$ENV_FILE" "$dir/config.env" 2>/dev/null || true
    chmod 600 "$dir/config.env" 2>/dev/null || true
}

# --- create -------------------------------------------------------------------

backup::create() {
    ui::scope backup
    stack::installed || { ui::err 'No stack configured.'; return 1; }
    mkdir -p "$BACKUP_DIR"

    local choice
    choice=$(ui::menu 'Backup method' \
        'Native|TeamCity archive via REST — portable, needs the server running' \
        'Logical|pg_dump + data directory — portable across PostgreSQL versions' \
        'Cold|tar every volume — complete, tied to this PostgreSQL major') || return 0

    case $choice in
        Native)  backup::_native ;;
        Logical) backup::_logical ;;
        Cold)    backup::_cold ;;
    esac
}

backup::_native() {
    ui::scope backup
    if ! stack::server_ready; then
        ui::err 'The native backup runs through REST; the server must be up.'
        return 1
    fi
    agents::ensure_token || return 1

    local name; name="teamcity-native-$(backup::_stamp)"
    ui::head 'Native backup'
    ui::note 'TeamCity writes the archive into its own data directory, then we copy it out.'

    if ! agents::_rest POST \
        "/app/rest/server/backup?includeConfigs=true&includeDatabase=true&includeBuildLogs=true&includePersonalChanges=true&fileName=$name" \
        '' 'text/plain' 'text/plain' >/dev/null 2>&1
    then
        ui::err 'TeamCity refused to start a backup.'
        ui::note 'The account needs server administration rights for this.'
        return 1
    fi

    ui::info 'Backup running on the server…'
    local waited=0
    while (( waited < 1800 )); do
        local state
        state=$(agents::_rest GET '/app/rest/server/backup' '' '' 'text/plain' 2>/dev/null || true)
        [[ $state == *Idle* || -z $state ]] && break
        sleep 5; waited=$(( waited + 5 ))
        ui::waiting "$waited" 'backing up'
    done

    local dir; dir=$(backup::_dir "$name"); mkdir -p "$dir"

    if docker run --rm \
        --volume "$(conf::volume datadir)":/src:ro \
        --volume "$dir":/out \
        "$BACKUP_HELPER" \
        sh -c "cp /src/backup/${name}*.zip /out/ 2>/dev/null" 2>/dev/null
    then
        backup::_write_manifest "$dir" native "$(backup::_pg_major)" datadir
        ui::ok "Saved to backups/$name"
        backup::prune
    else
        ui::err "The archive was not found in the data directory's backup folder."
        ui::note "Check $(conf::url)/admin/admin.html?item=backup"
        return 1
    fi
}

backup::_logical() {
    ui::scope backup
    [[ $TC_DB == postgres ]] || { ui::err 'Logical backup applies to the PostgreSQL stack only.'; return 1; }

    local name; name="teamcity-logical-$(backup::_stamp)"
    local dir; dir=$(backup::_dir "$name"); mkdir -p "$dir"

    ui::head 'Logical backup'

    # The dump comes first, while the database is up.
    if ! stack::compose ps --services --status running 2>/dev/null | grep -q '^db$'; then
        ui::spin 'Starting the database' -- stack::compose up --detach db
        sleep 5
    fi

    local pg_major; pg_major=$(backup::_pg_major)

    ui::spin 'Dumping the database' -- bash -c "
        docker compose --file '$COMPOSE_FILE' --project-directory '$STACK_DIR' --env-file '$ENV_FILE' \
            exec -T db pg_dump -U '$TC_PG_USER' -d '$TC_PG_DB' -Fc > '$dir/database.dump'
    " || { ui::err 'pg_dump failed.'; return 1; }

    # The data directory is only consistent with the server stopped.
    ui::spin 'Stopping the server for a consistent data directory' -- stack::compose stop server
    BACKUP_DIR="$dir" backup::_tar_volume "$(conf::volume datadir)" 'datadir.tgz' \
        || { ui::err 'Could not archive the data directory.'; return 1; }
    ui::spin 'Restarting the server' -- stack::compose up --detach server

    backup::_write_manifest "$dir" logical "$pg_major" datadir
    ui::ok "Saved to backups/$name  ($(du -sh "$dir" | cut -f1))"
    backup::prune
}

backup::_cold() {
    ui::scope backup
    backup::_check_space || return 1

    local name; name="teamcity-cold-$(backup::_stamp)"
    local dir; dir=$(backup::_dir "$name"); mkdir -p "$dir"

    ui::head 'Cold backup'

    local pg_major=''
    if [[ $TC_DB == postgres ]]; then
        stack::compose ps --services --status running 2>/dev/null | grep -q '^db$' \
            && pg_major=$(backup::_pg_major)
    fi

    local was_running=0
    [[ $(stack::state) != stopped ]] && was_running=1

    ui::spin 'Stopping the stack' -- stack::compose stop

    local -a volumes; mapfile -t volumes < <(render::volume_names)
    local -a captured=()
    local vol short

    for vol in "${volumes[@]}"; do
        docker volume inspect "$vol" >/dev/null 2>&1 || continue
        short=${vol#"${TC_STACK}_"}
        if BACKUP_DIR="$dir" backup::_tar_volume "$vol" "$short.tgz"; then
            captured+=("$short")
            ui::note "  $short"
        else
            ui::warn "  $short — skipped"
        fi
    done

    backup::_write_manifest "$dir" cold "$pg_major" "${captured[@]}"

    (( was_running == 1 )) && ui::spin 'Restarting the stack' -- stack::compose up --detach

    ui::ok "Saved ${#captured[@]} volume(s) to backups/$name  ($(du -sh "$dir" | cut -f1))"
    backup::prune

    # `if`, not a trailing `&&`: on an HSQLDB stack pg_major is empty, the test
    # is false, and the whole function would return 1 — reporting a successful
    # backup as a failure. That aborted an upgrade in testing.
    if [[ -n $pg_major ]]; then
        ui::note "Tied to PostgreSQL $pg_major — restore refuses a different major."
    fi

    return 0
}

# --- list ---------------------------------------------------------------------

backup::list() {
    ui::head 'Archives'
    mkdir -p "$BACKUP_DIR"

    local -a dirs
    mapfile -t dirs < <(find "$BACKUP_DIR" -maxdepth 1 -mindepth 1 -type d -name 'teamcity-*' | sort -r)

    if (( ${#dirs[@]} == 0 )); then
        ui::note 'No archives yet.'
        return 0
    fi

    {
        printf 'ARCHIVE,KIND,STACK,TEAMCITY,PG,SIZE,CREATED\n'
        local d m
        for d in "${dirs[@]}"; do
            m="$d/manifest.json"
            if [[ -f $m ]]; then
                printf '%s,%s,%s,%s,%s,%s,%s\n' \
                    "$(basename "$d")" \
                    "$(jq -r '.kind // "?"' "$m")" \
                    "$(jq -r '.stack // "?"' "$m")" \
                    "$(jq -r '.teamcity_version // "?"' "$m")" \
                    "$(jq -r 'if .postgres_major == "" then "-" else (.postgres_major // "-") end' "$m")" \
                    "$(du -sh "$d" | cut -f1)" \
                    "$(jq -r '.created // "?"' "$m" | cut -dT -f1)"
            else
                printf '%s,incomplete,-,-,-,%s,-\n' "$(basename "$d")" "$(du -sh "$d" | cut -f1)"
            fi
        done
    } | column -t -s, >&2
}

# --- restore ------------------------------------------------------------------

backup::restore() {
    ui::scope backup
    stack::installed || { ui::err 'No stack configured.'; return 1; }

    local -a dirs
    mapfile -t dirs < <(find "$BACKUP_DIR" -maxdepth 1 -mindepth 1 -type d -name 'teamcity-*' \
        -exec test -f '{}/manifest.json' ';' -print | sort -r)

    if (( ${#dirs[@]} == 0 )); then
        ui::err 'No complete archives in backups/.'
        return 1
    fi

    local -a names=()
    local d; for d in "${dirs[@]}"; do names+=("$(basename "$d")"); done

    local pick; pick=$(ui::choose 'Restore which archive?' "${names[@]}") || return 0
    local dir="$BACKUP_DIR/$pick" manifest="$BACKUP_DIR/$pick/manifest.json"

    # Names cannot carry it, so nothing on the chooser distinguishes an archive
    # taken from a different stack. Restoring one is a legitimate thing to want —
    # cloning an instance — but never a thing to do by accident.
    local owner; owner=$(backup::_archive_stack "$dir")
    if [[ -n $owner && $owner != "$TC_STACK" ]]; then
        ui::blank
        ui::warn "That archive was taken from the stack '$owner', not '$TC_STACK'."
        ui::note "Its volumes will be restored into $TC_STACK's, replacing them."
        ui::confirm "Restore $owner's backup into $TC_STACK?" || return 0
    fi

    backup::_show_manifest "$manifest"
    backup::_check_compatible "$manifest" || return 1

    ui::blank
    ui::confirm_typed "$TC_STACK" \
        "This replaces everything in '$TC_STACK' with the contents of $pick." || return 0

    local kind; kind=$(jq -r '.kind' "$manifest")

    conf::lock; trap conf::unlock RETURN
    # `down`, not `stop`: volumes cannot be rewritten while containers hold them.
    ui::spin 'Stopping and removing containers' -- stack::compose down

    case $kind in
        cold)    backup::_restore_cold "$dir" "$manifest" ;;
        logical) backup::_restore_logical "$dir" ;;
        native)  backup::_restore_native "$dir" ;;
    esac
    local rc=$?

    (( rc == 0 )) || { ui::err 'Restore failed; the stack was left stopped.'; return 1; }

    # An archive carries its own database credentials in the restored
    # database.properties, and the PostgreSQL volume it came with expects them.
    # stack/.env keeps whatever it held before the restore, so without this the
    # config on disk claims a password the database does not have — harmless
    # until the pgdata volume is ever recreated, at which point the two disagree
    # and the server cannot connect.
    backup::_realign_db_password "$dir"
    backup::_report_config_drift "$dir"

    ui::spin 'Starting the stack' -- stack::compose up --detach
    stack::_await_ready
}

# Brings stack/.env back in step with the credentials inside the restored
# data directory.
backup::_realign_db_password() {
    local dir=${1:-}
    [[ $TC_DB == postgres ]] || return 0

    local restored=''

    # Prefer the archive's own configuration; fall back to reading it out of the
    # restored data directory for archives written before config.env existed.
    if [[ -n $dir && -f "$dir/config.env" ]]; then
        restored=$(grep '^TC_PG_PASSWORD=' "$dir/config.env" 2>/dev/null \
            | sed "s/^TC_PG_PASSWORD='\{0,1\}//;s/'\{0,1\}$//")
    fi

    if [[ -z $restored ]]; then
        restored=$(docker run --rm -v "$(conf::volume datadir)":/d:ro alpine:3.22 \
            sh -c 'grep "^connectionProperties.password=" /d/config/database.properties 2>/dev/null | cut -d= -f2-' 2>/dev/null)
    fi

    [[ -n $restored ]] || return 0
    [[ $restored == "$TC_PG_PASSWORD" ]] && return 0

    TC_PG_PASSWORD=$restored
    conf::save
    ui::note 'Database password in stack/.env realigned with the restored archive.'
    log::info backup.restore 'realigned TC_PG_PASSWORD with the restored configuration'
}

# Settings that differ between the archive and the current configuration, other
# than the credentials which are realigned automatically. Reported, never
# changed: a restore should not silently move the port out from under you.
backup::_report_config_drift() {
    local dir=$1
    [[ -f "$dir/config.env" ]] || return 0

    local -a drift=()
    local key archived current
    for key in TC_STACK TC_VERSION TC_PORT TC_TZ TC_DB TC_PG_VERSION TC_AGENTS TC_AGENT_IMAGE TC_AGENT_DOCKER; do
        archived=$(grep "^$key=" "$dir/config.env" 2>/dev/null | sed "s/^$key='\{0,1\}//;s/'\{0,1\}$//")
        current=${!key}
        [[ -n $archived && $archived != "$current" ]] && drift+=("  $key: archive '$archived', now '$current'")
    done

    (( ${#drift[@]} > 0 )) || return 0
    ui::blank
    ui::warn 'The archive was taken with different settings, left as they are:'
    printf '%s\n' "${drift[@]}" >&2
    ui::note 'Change them in stack/.env if you want the archived values back.'
}

backup::_show_manifest() {
    local m=$1
    ui::head 'Archive'
    {
        printf 'FIELD,VALUE\n'
        printf 'Kind,%s\n'      "$(jq -r '.kind' "$m")"
        printf 'Stack,%s\n'     "$(jq -r '.stack' "$m")"
        printf 'TeamCity,%s\n'  "$(jq -r '.teamcity_version' "$m")"
        printf 'Database,%s\n'  "$(jq -r '.database' "$m")"
        printf 'PostgreSQL,%s\n' "$(jq -r 'if (.postgres_major // "") == "" then "-" else .postgres_major end' "$m")"
        printf 'Agents,%s\n'    "$(jq -r '.agents' "$m")"
        printf 'Created,%s\n'   "$(jq -r '.created' "$m")"
    } | column -t -s, >&2
}

# Three ways a restore produces a server that will not start. Each is cheap to
# detect here and confusing to diagnose afterwards.
backup::_check_compatible() {
    local m=$1
    local b_version b_db b_pg
    b_version=$(jq -r '.teamcity_version' "$m")
    b_db=$(jq -r '.database' "$m")
    b_pg=$(jq -r '.postgres_major // ""' "$m")

    if [[ $b_db != "$TC_DB" ]]; then
        ui::err "The archive holds a '$b_db' stack; this one runs '$TC_DB'."
        ui::note 'Reconfigure the stack to match, or use a native archive, which'
        ui::note 'is the only kind that moves between database backends.'
        return 1
    fi

    # TeamCity refuses to start against a data directory written by a newer
    # version, and the error does not say so plainly.
    local newest
    newest=$(printf '%s\n%s\n' "$b_version" "$TC_VERSION" | sort -Vr | head -1)
    if [[ $newest == "$b_version" && $b_version != "$TC_VERSION" ]]; then
        ui::err "The archive is from TeamCity $b_version; this stack runs $TC_VERSION."
        ui::note "A newer data directory will not load on an older server."
        ui::note "Set TC_VERSION to $b_version and try again."
        return 1
    fi

    local kind; kind=$(jq -r '.kind' "$m")
    if [[ $kind == cold && -n $b_pg && $TC_DB == postgres && $b_pg != "$TC_PG_VERSION" ]]; then
        ui::err "Cold archive holds a PostgreSQL $b_pg data directory; this stack runs $TC_PG_VERSION."
        ui::note 'A raw PGDATA directory does not load across major versions.'
        ui::note "Either set TC_PG_VERSION=$b_pg, or restore a logical or native archive."
        return 1
    fi

    return 0
}

backup::_restore_cold() {
    local dir=$1 manifest=$2
    local -a volumes; mapfile -t volumes < <(jq -r '.volumes[]' "$manifest")

    local short vol
    for short in "${volumes[@]}"; do
        vol="${TC_STACK}_${short}"
        [[ -f "$dir/$short.tgz" ]] || { ui::warn "missing $short.tgz, skipping"; continue; }
        backup::_create_volume "$vol"
        if BACKUP_DIR="$dir" backup::_untar_volume "$vol" "$short.tgz"; then
            ui::note "  restored $short"
        else
            ui::err "  failed to restore $short"
            return 1
        fi
    done
}

backup::_restore_logical() {
    local dir=$1

    local vol; vol=$(conf::volume datadir)
    backup::_create_volume "$vol"
    BACKUP_DIR="$dir" backup::_untar_volume "$vol" 'datadir.tgz' \
        || { ui::err 'Could not restore the data directory.'; return 1; }
    ui::note '  restored datadir'

    # A logical dump needs an empty database to land in, so the old volume goes.
    docker volume rm "$(conf::volume pgdata)" >/dev/null 2>&1 || true
    ui::spin 'Starting a fresh database' -- stack::compose up --detach db

    ui::info 'Waiting for the database to accept connections…'
    local waited=0
    while (( waited < 120 )); do
        stack::compose exec -T db pg_isready -U "$TC_PG_USER" >/dev/null 2>&1 && break
        sleep 3; waited=$(( waited + 3 ))
        ui::waiting "$waited" 'waiting for the database'
    done
    (( waited < 120 )) || ui::warn 'The database did not become ready within 120s; loading anyway.'


    ui::spin 'Loading the dump' -- bash -c "
        docker compose --file '$COMPOSE_FILE' --project-directory '$STACK_DIR' --env-file '$ENV_FILE' \
            exec -T db pg_restore -U '$TC_PG_USER' -d '$TC_PG_DB' --clean --if-exists --no-owner \
            < '$dir/database.dump'
    " || { ui::warn 'pg_restore reported errors; check the output above.'; }

    ui::note '  restored database'
}

backup::_restore_native() {
    local dir=$1
    local archive
    archive=$(find "$dir" -maxdepth 1 -name '*.zip' | head -1)
    [[ -n $archive ]] || { ui::err 'No .zip in that archive directory.'; return 1; }

    ui::head 'Native restore'
    ui::note 'This runs maintainDB inside the server image, with the database up'
    ui::note 'and the server stopped.'

    # maintainDB refuses to restore into a data directory whose config/ is not
    # empty — it will not overwrite an existing configuration. That makes the
    # obvious approach circular: it also needs a database.properties to know
    # which database to restore *into*, and pointing -T at a file inside the
    # data directory is precisely what makes config/ non-empty.
    #
    # So the target configuration lives outside the data directory, on its own
    # mount, and the data directory is emptied first except for the JDBC driver
    # that maintainDB needs to reach PostgreSQL at all.
    local vol; vol=$(conf::volume datadir)
    backup::_create_volume "$vol"

    # Under the project directory, not /tmp. Bind-mount sources are resolved by
    # the *daemon*, on the host — a path from the console container's own mktemp
    # does not exist there, and the mount silently produces an empty directory.
    local staging="$BACKUP_DIR/.restore-staging-$$"
    mkdir -p "$staging" || return 1
    printf 'connectionUrl=jdbc:postgresql://db:5432/%s\nconnectionProperties.user=%s\nconnectionProperties.password=%s\n' \
        "$TC_PG_DB" "$TC_PG_USER" "$TC_PG_PASSWORD" >"$staging/database.properties"

    ui::info 'Clearing the data directory, keeping only the JDBC driver…'
    if ! docker run --rm -v "$vol":/d alpine:3.22 sh -c '
            mkdir -p /tmp/keep
            cp /d/lib/jdbc/postgresql-*.jar /tmp/keep/ 2>/dev/null || true
            find /d -mindepth 1 -delete
            mkdir -p /d/lib/jdbc
            cp /tmp/keep/*.jar /d/lib/jdbc/ 2>/dev/null || true
            chown -R 1000:1000 /d' >/dev/null 2>&1
    then
        ui::err 'Could not prepare the data directory.'
        rm -rf "$staging"
        return 1
    fi

    ui::spin 'Starting the database' -- stack::compose up --detach db

    ui::info 'Waiting for the database…'
    local waited=0
    while (( waited < 120 )); do
        stack::compose exec -T db pg_isready -U "$TC_PG_USER" >/dev/null 2>&1 && break
        sleep 3; waited=$(( waited + 3 ))
        ui::waiting "$waited" 'waiting for the database'
    done

    # maintainDB also refuses a target database that already has tables. A
    # restore replaces the database by definition — the stack name has already
    # been typed to confirm that — so clear the schema rather than leaving the
    # command to fail on a precondition the caller cannot see.
    ui::info 'Clearing the target database…'
    if ! stack::compose exec -T db psql -U "$TC_PG_USER" -d "$TC_PG_DB" -q \
            -c 'DROP SCHEMA IF EXISTS public CASCADE;' \
            -c 'CREATE SCHEMA public;' \
            -c "GRANT ALL ON SCHEMA public TO \"$TC_PG_USER\";" >/dev/null 2>&1
    then
        ui::err 'Could not clear the target database.'
        rm -rf "$staging"
        return 1
    fi

    local rc=0
    docker run --rm \
        --network "${TC_STACK}_default" \
        --user 1000:1000 \
        --volume "$vol":/data/teamcity_server/datadir \
        --volume "$dir":/restore:ro \
        --volume "$staging":/target:ro \
        --entrypoint /opt/teamcity/bin/maintainDB.sh \
        "jetbrains/teamcity-server:$TC_VERSION" \
        restore -A /data/teamcity_server/datadir \
                -F "/restore/$(basename "$archive")" \
                -T /target/database.properties || rc=$?

    rm -rf "$staging"

    if (( rc != 0 )); then
        ui::err 'maintainDB restore failed.'
        ui::note 'The archive may predate this TeamCity version, or the target'
        ui::note 'database may be unreachable. The maintainDB output is above.'
        return 1
    fi

    ui::note '  restored via maintainDB'
}
