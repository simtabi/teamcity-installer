#!/usr/bin/env bash
#
# upgrade.sh — move the stack to a different TeamCity version.
#
# Two things make an unattended TeamCity upgrade unpleasant, and both are handled
# here:
#
#  * Downgrades. TeamCity refuses to start against a data directory written by a
#    newer version, and says so in a way that does not obviously mean "you went
#    backwards". Cheaper to refuse up front.
#
#  * The maintenance page. On a version change TeamCity serves a maintenance UI
#    that will not proceed until you supply a one-time token, which it prints to
#    the server log and nowhere else. Left to find it themselves, users see a
#    blank page and assume the upgrade hung.

upgrade::run() {
    ui::scope upgrade
    stack::installed || { ui::err 'No stack configured.'; return 1; }

    ui::head 'Upgrade'
    ui::note "Currently on TeamCity $TC_VERSION."

    local -a versions
    mapfile -t versions < <(validate::available_versions 2>/dev/null | head -15)

    local target
    if (( ${#versions[@]} == 0 )); then
        ui::warn 'Could not reach Docker Hub; enter a version manually.'
        target=$(ui::ask 'Target version' "$TC_VERSION" validate::tc_version) || return 0
    else
        target=$(ui::choose 'Upgrade to' "${versions[@]}") || return 0
    fi

    [[ $target == "$TC_VERSION" ]] && { ui::note 'Already on that version.'; return 0; }

    upgrade::_check_direction "$target" || return 1

    ui::blank
    ui::warn "TeamCity $TC_VERSION → $target"
    ui::note 'The data directory is upgraded in place and cannot be rolled back'
    ui::note 'without restoring a backup, so one is taken first.'
    ui::confirm 'Continue?' || return 0

    # Not optional. An upgrade without a backup is a one-way door.
    ui::head 'Pre-upgrade backup'
    if ! backup::_cold; then
        ui::err 'Backup failed; the upgrade is cancelled.'
        return 1
    fi
    local safety; safety=$(find "$BACKUP_DIR" -maxdepth 1 -type d -name 'teamcity-cold-*' | sort -r | head -1)

    local previous=$TC_VERSION
    TC_VERSION=$target
    conf::save

    conf::lock; trap conf::unlock RETURN
    if ! render::compose; then
        TC_VERSION=$previous; conf::save
        return 1
    fi

    ui::head "Pulling $target"
    if ! stack::compose pull; then
        TC_VERSION=$previous; conf::save; render::compose
        ui::err "Could not pull the $target images; reverted to $previous."
        return 1
    fi

    ui::spin 'Recreating containers' -- stack::compose up --detach --remove-orphans

    upgrade::_watch_maintenance "$safety"
}

# Compares versions with sort -V so 2026.1.10 correctly sorts above 2026.1.9.
upgrade::_check_direction() {
    local target=$1 newest
    newest=$(printf '%s\n%s\n' "$target" "$TC_VERSION" | sort -Vr | head -1)

    if [[ $newest == "$TC_VERSION" ]]; then
        ui::err "$target is older than the running $TC_VERSION."
        ui::note 'The data directory has already been upgraded by the newer server,'
        ui::note 'and an older one will refuse to load it. To go back, restore a'
        ui::note "backup taken while $target was running."
        return 1
    fi
    return 0
}

upgrade::_watch_maintenance() {
    ui::head 'Data directory upgrade'
    ui::note 'Watching the server log for the maintenance token…'

    local waited=0 token=''
    while (( waited < 300 )); do
        if stack::server_ready; then
            ui::blank
            ui::ok "TeamCity $TC_VERSION is up at $(conf::url)"
            ui::note 'No maintenance confirmation was needed.'
            return 0
        fi

        # Reuses the same extractor as `./tc token` rather than re-parsing the
        # log here. An earlier version grepped for any 8+ alphanumeric run and
        # took the last one, which cheerfully returned "browser" from the line
        # "…better use a private browser window" sitting right beside the token.
        if [[ $(stack::server_state) == setup ]]; then
            token=$(stack::super_user_token)
            ui::blank
            ui::warn 'TeamCity needs you to confirm the data directory upgrade.'
            ui::note "  1. Open  $(conf::url)"

            if [[ -n $token ]]; then
                if ui::plain; then
                    ui::note "  2. Enter this token (leave the username blank): $token"
                else
                    ui::note '  2. Enter this token, leaving the username blank:'
                    gum style --foreground "$UI_ACCENT" --bold --padding '0 6' "$token" >&2
                fi
            else
                ui::note '  2. It will ask for a token. Fetch it with:  ./tc token'
            fi

            ui::note '  3. Confirm the upgrade and wait for it to finish.'
            return 0
        fi

        sleep 5; waited=$(( waited + 5 ))
        (( waited % 30 == 0 )) && ui::note "still starting… ${waited}s"
    done

    ui::warn 'The server did not come up within 5 minutes.'
    ui::note 'Check the log with:  ./tc logs server'
    [[ -n ${1:-} ]] && ui::note "To roll back, restore: $(basename "$1")"
    return 1
}
