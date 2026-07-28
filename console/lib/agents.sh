#!/usr/bin/env bash
#
# agents.sh — scale, inspect and authorize build agents.
#
# Authorizing agents is the one step a stock TeamCity install leaves manual, and
# it is easy to miss: agents connect, appear under "Unauthorized", and silently
# take no builds. Automating it via REST is most of the value here.

agents::menu() {
    ui::scope agents
    while true; do
        local choice
        choice=$(ui::menu 'Agents' \
            'List|connected, authorized and enabled state' \
            'Authorize|approve agents waiting for authorization' \
            'Scale|change how many agents run' \
            'Prune volumes|remove volumes left behind by removed agents' \
            'Back|') || return 0

        case $choice in
            List)            agents::list; ui::pause ;;
            Authorize)       agents::authorize; ui::pause ;;
            Scale)           agents::scale; ui::pause ;;
            'Prune volumes') agents::prune; ui::pause ;;
            Back)            return 0 ;;
        esac
    done
}

# --- REST ---------------------------------------------------------------------

TC_REST_BASE=''

agents::_rest_base() {
    [[ -n $TC_REST_BASE ]] || TC_REST_BASE="http://host.docker.internal:$TC_PORT"
    printf '%s' "$TC_REST_BASE"
}

# agents::_rest <method> <path> [body] [content-type]
agents::_rest() {
    local method=$1 path=$2 body=${3:-} ctype=${4:-application/json}
    local token; token=$(conf::token) || return 2

    local -a args=(
        --silent --show-error --fail --max-time "${TC_REST_TIMEOUT:-20}"
        --request "$method"
        --header "Authorization: Bearer $token"
        --header 'Accept: application/json'
    )
    [[ -n $body ]] && args+=(--header "Content-Type: $ctype" --data "$body")

    curl "${args[@]}" "$(agents::_rest_base)$path"
}

# Prompts for a token, verifies it against the live server, and stores it.
agents::ensure_token() {
    if conf::token >/dev/null 2>&1; then
        if agents::_rest GET /app/rest/server >/dev/null 2>&1; then return 0; fi
        ui::warn 'The stored access token no longer works.'
        conf::clear_token
    fi

    if ! stack::server_ready; then
        ui::err 'TeamCity is not answering; start the stack first.'
        return 1
    fi

    ui::head 'Access token'
    ui::note "The console needs a token to talk to TeamCity's REST API."
    ui::note '  1. Open '"$(conf::url)"
    ui::note '  2. Your profile (top right) → Access Tokens → Create access token'
    ui::note '  3. Give it permission to manage agents, then paste it here.'
    ui::note 'It is stored in stack/.secrets (mode 600) and never in .env,'
    ui::note 'so it cannot leak through docker compose config output.'
    ui::blank

    local token
    token=$(ui::secret 'Access token' '' validate::rest_token) || return 1
    [[ -n $token ]] || { ui::err 'No token entered.'; return 1; }

    conf::save_token "$token"

    if ! agents::_rest GET /app/rest/server >/dev/null 2>&1; then
        conf::clear_token
        ui::err 'TeamCity rejected that token.'
        ui::note 'Check it was copied whole, and that it has not expired.'
        return 1
    fi

    ui::ok 'Token verified and stored.'
}

agents::_manual_hint() {
    ui::blank
    ui::note 'You can always do this in the UI instead:'
    ui::note "  $(conf::url)/agents.html?tab=unauthorizedAgents"
}

# --- list ---------------------------------------------------------------------

agents::list() {
    ui::scope agents
    ui::head 'Agents'

    if ! agents::ensure_token; then agents::_manual_hint; return 1; fi

    local json
    json=$(agents::_rest GET '/app/rest/agents?locator=defaultFilter:false&fields=count,agent(id,name,connected,authorized,enabled)') \
        || { ui::err 'Could not list agents.'; return 1; }

    local count; count=$(printf '%s' "$json" | jq -r '.count // 0')
    if (( count == 0 )); then
        ui::note 'No agents known to the server yet.'
        ui::note 'They register a few seconds after starting; try again shortly.'
        return 0
    fi

    {
        printf 'ID,NAME,CONNECTED,AUTHORIZED,ENABLED\n'
        printf '%s' "$json" | jq -r '.agent[]
            | [ .id, .name,
                (if .connected  then "yes" else "no" end),
                (if .authorized then "yes" else "no" end),
                (if .enabled    then "yes" else "no" end) ]
            | @csv' | tr -d '"'
    } | column -t -s, >&2

    local authorized
    authorized=$(printf '%s' "$json" | jq -r '[.agent[] | select(.authorized)] | length')

    ui::blank
    if (( authorized > TC_FREE_AGENTS )); then
        ui::warn "$authorized agents authorized; the free licence covers $TC_FREE_AGENTS."
        ui::note 'TeamCity pauses the build queue above the licensed count.'
    else
        ui::ok "$authorized of $count agent(s) authorized."
    fi
}

# --- authorize ----------------------------------------------------------------

agents::authorize() {
    ui::scope agents
    ui::head 'Authorize agents'

    if ! agents::ensure_token; then agents::_manual_hint; return 1; fi

    local json
    json=$(agents::_rest GET '/app/rest/agents?locator=authorized:false&fields=count,agent(id,name,connected)') \
        || { ui::err 'Could not query pending agents.'; agents::_manual_hint; return 1; }

    local count; count=$(printf '%s' "$json" | jq -r '.count // 0')
    if (( count == 0 )); then
        ui::ok 'No agents are waiting for authorization.'
        return 0
    fi

    local -a pending
    mapfile -t pending < <(printf '%s' "$json" | jq -r '.agent[] | "\(.id)|\(.name)"')

    ui::note "$count agent(s) waiting:"
    local entry
    for entry in "${pending[@]}"; do ui::note "  ${entry#*|}"; done
    ui::blank

    # Warn before creating a state that pauses the queue.
    local already
    already=$(agents::_rest GET '/app/rest/agents?locator=authorized:true&fields=count' \
        | jq -r '.count // 0' 2>/dev/null || echo 0)
    if (( already + count > TC_FREE_AGENTS )); then
        ui::warn "This would authorize $(( already + count )) agents; the free licence covers $TC_FREE_AGENTS."
        ui::note 'Above the limit TeamCity pauses the whole build queue.'
        ui::confirm 'Authorize anyway?' || return 0
    else
        ui::confirm "Authorize all $count?" yes || return 0
    fi

    local id name ok=0 failed=0
    for entry in "${pending[@]}"; do
        id=${entry%%|*}; name=${entry#*|}
        if agents::_authorize_one "$id"; then
            ui::ok "authorized $name"; ok=$((ok+1))
        else
            ui::err "failed to authorize $name"; failed=$((failed+1))
        fi
    done

    ui::blank
    if (( failed == 0 )); then
        ui::ok "$ok agent(s) authorized."
    else
        ui::warn "$ok authorized, $failed failed."
        agents::_manual_hint
    fi
}

# TeamCity exposes both /authorizedInfo (documented) and /authorized (plain
# boolean). Which one a build accepts has varied across versions, so try the
# documented path first and fall back rather than failing on a path detail.
agents::_authorize_one() {
    local id=$1
    agents::_rest PUT "/app/rest/agents/id:$id/authorizedInfo" \
        '{"status":true,"comment":{"text":"authorized by the TeamCity control console"}}' \
        'application/json' >/dev/null 2>&1 && return 0

    agents::_rest PUT "/app/rest/agents/id:$id/authorized" 'true' 'text/plain' >/dev/null 2>&1
}

# --- why there is no automatic authorization ------------------------------------
#
# TeamCity documents an internal property, teamcity.agentAutoAuthorize.
# authorizationToken, that is widely described as authorizing any agent
# presenting the same value in its buildAgent.properties. It was implemented
# here and it does not work on 2026.1.3:
#
#   * The server reads the property — it appears in the startup log — and agents
#     presenting the matching token still register as Unauthorized.
#   * The agent image only writes AGENT_TOKEN into buildAgent.properties when
#     that file has no token yet, so on an existing stack the setting is
#     accepted and silently ignored.
#   * Rewriting the token in the conf volume to force the issue is worse: the
#     server treats a changed token as a *different agent*, so the originals are
#     orphaned and duplicates appear as "<name>-1".
#
# Rather than ship something that quietly does nothing, authorization is manual
# and the console makes it a single action. If a future TeamCity makes the
# property work as described, this is the place to reinstate it.

# --- scale --------------------------------------------------------------------

agents::scale() {
    ui::scope agents
    ui::head 'Scale agents'
    stack::installed || { ui::err 'No stack configured.'; return 1; }

    ui::note "Currently $TC_AGENTS agent(s). The free licence covers $TC_FREE_AGENTS."

    local previous=$TC_AGENTS wanted
    wanted=$(ui::ask 'How many agents' "$TC_AGENTS" validate::agent_count) || return 0
    [[ $wanted == "$previous" ]] && { ui::note 'Unchanged.'; return 0; }

    TC_AGENTS=$wanted
    conf::save

    conf::lock; trap conf::unlock RETURN
    if ! render::compose; then TC_AGENTS=$previous; conf::save; return 1; fi
    ui::spin "Applying $wanted agent(s)" -- stack::compose up --detach --remove-orphans

    ui::ok "Now running $wanted agent(s)."

    if (( wanted < previous )); then
        ui::blank
        ui::note "Volumes for agents $(( wanted + 1 ))–$previous still exist, holding their"
        ui::note 'authorization tokens and caches. Scaling back up reuses them.'
        ui::confirm 'Delete them now instead?' && agents::_drop_volumes "$(( wanted + 1 ))" "$previous"
    elif (( wanted > previous )); then
        ui::note 'New agents need authorizing — use Agents → Authorize.'
    fi
}

agents::_drop_volumes() {
    local from=$1 to=$2 n entry vol removed=0

    for (( n = from; n <= to; n++ )); do
        for entry in "${TC_AGENT_VOLUMES[@]}" 'docker:'; do
            vol="${TC_STACK}_agent-${n}-${entry%%:*}"
            docker volume rm "$vol" >/dev/null 2>&1 && removed=$((removed+1))
        done
    done

    ui::ok "Removed $removed volume(s)."
}

# --- prune --------------------------------------------------------------------

# Volumes named for this stack that the current compose file no longer
# references — typically left behind by scaling down or renaming the stack.
agents::prune() {
    ui::scope agents
    ui::head 'Prune orphan volumes'
    stack::installed || { ui::err 'No stack configured.'; return 1; }

    local -a expected actual orphans=()
    mapfile -t expected < <(render::volume_names)
    mapfile -t actual < <(docker volume ls --quiet --filter "name=^${TC_STACK}_" 2>/dev/null)

    local vol
    for vol in "${actual[@]}"; do
        local found=0 want
        for want in "${expected[@]}"; do [[ $vol == "$want" ]] && { found=1; break; }; done
        (( found == 0 )) && orphans+=("$vol")
    done

    if (( ${#orphans[@]} == 0 )); then
        ui::ok 'No orphan volumes.'
        return 0
    fi

    ui::warn "${#orphans[@]} volume(s) belong to '$TC_STACK' but are not in the current stack:"
    for vol in "${orphans[@]}"; do
        ui::note "  $vol  ($(docker volume inspect "$vol" --format '{{.CreatedAt}}' 2>/dev/null))"
    done

    ui::blank
    ui::confirm_typed "$TC_STACK" \
        'Deleting these destroys whatever build data and agent tokens they hold.' || return 0

    local removed=0
    for vol in "${orphans[@]}"; do
        if docker volume rm "$vol" >/dev/null 2>&1; then
            removed=$(( removed + 1 ))
        else
            ui::warn "could not remove $vol (still in use?)"
        fi
    done
    ui::ok "Removed $removed volume(s)."
}
