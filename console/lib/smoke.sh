#!/usr/bin/env bash
#
# smoke.sh — prove the stack can actually build something.
#
# Everything else this console checks is a precondition. Containers healthy,
# volumes mapped, REST answering, agents connected and authorized: all necessary,
# none of it evidence that a build will run. A CI server that cannot execute a
# build step is broken no matter how green its status page is, and until this
# existed nobody had ever asked it to.
#
# So: create a throwaway project with one command-line step, queue it, wait for a
# real agent to pick it up, and require three things — the build finished, it
# succeeded, and the marker string this run generated appears in the log the
# agent produced. The third is what separates "TeamCity said SUCCESS" from "the
# command actually ran": a build with a step that silently never executed can
# still report success, and the log is the only place that shows the difference.
#
# The project is deleted afterwards, on every exit path including failure.

SMOKE_PROJECT_ID='TcConsoleSmoke'
SMOKE_BUILD_ID='TcConsoleSmoke_Probe'

smoke::run() {
    ui::scope smoke
    stack::installed || { ui::err 'No stack configured.'; return 1; }

    ui::head 'Smoke build'
    ui::note 'Creates a throwaway build, runs it on an agent, then removes it.'

    if [[ $(stack::server_state) != ready ]]; then
        ui::err "TeamCity is not ready: $(stack::not_ready_reason)."
        ui::note 'Start it with  ./tc up  and try again.'
        return 1
    fi

    # A build with nowhere to run sits in the queue until the timeout, and
    # "timed out" is a much worse message than "no agent could take it".
    local ready_agents
    ready_agents=$(agents::_rest GET '/app/rest/agents?locator=authorized:true,connected:true' 2>/dev/null \
        | jq -r '.count // 0')
    if [[ ${ready_agents:-0} == 0 ]]; then
        ui::err 'No connected, authorized agent to run a build on.'
        ui::note 'Check  ./tc agents  — a build would queue forever.'
        return 1
    fi
    ui::note "$ready_agents agent(s) available."

    # Removed whatever happens next, including a failure part-way through
    # creation. A leftover project would make the next run fail on a name clash.
    trap 'smoke::_cleanup' RETURN

    smoke::_cleanup_quiet          # in case an earlier run died before its trap

    local marker; marker="tc-smoke-$(date +%s)-$$"

    smoke::_create "$marker" || return 1

    local build_id
    build_id=$(smoke::_queue) || return 1
    ui::note "Queued as build #$build_id."

    smoke::_await "$build_id" || return 1
    smoke::_assert "$build_id" "$marker"
}

# --- setup --------------------------------------------------------------------

smoke::_create() {
    local marker=$1

    agents::_rest POST /app/rest/projects \
        "$(jq -n --arg id "$SMOKE_PROJECT_ID" '{id: $id, name: "tc console smoke test", parentProject: {locator: "_Root"}}')" \
        >/dev/null 2>&1 || {
        ui::err 'Could not create the smoke-test project.'
        ui::note 'The console needs administrator rights over REST. Try  ./tc doctor'
        return 1
    }

    agents::_rest POST /app/rest/buildTypes \
        "$(jq -n --arg id "$SMOKE_BUILD_ID" --arg p "$SMOKE_PROJECT_ID" \
            '{id: $id, name: "probe", project: {id: $p}}')" \
        >/dev/null 2>&1 || { ui::err 'Could not create the build configuration.'; return 1; }

    # A plain shell step. No VCS root: checking out a repository would test
    # network access to somewhere else, not this stack.
    agents::_rest POST "/app/rest/buildTypes/id:$SMOKE_BUILD_ID/steps" \
        "$(jq -n --arg script "printf '%s\\n' '$marker'
uname -sm
echo \"agent: \$HOSTNAME\"" \
            '{name: "probe", type: "simpleRunner", properties: {property: [
                {name: "script.content",         value: $script},
                {name: "teamcity.step.mode",     value: "default"},
                {name: "use.custom.script",      value: "true"}]}}')" \
        >/dev/null 2>&1 || { ui::err 'Could not add the build step.'; return 1; }
}

smoke::_queue() {
    local out
    out=$(agents::_rest POST /app/rest/buildQueue \
        "$(jq -n --arg id "$SMOKE_BUILD_ID" '{buildType: {id: $id}}')" 2>/dev/null) || {
        ui::err 'Could not queue the build.' >&2
        return 1
    }
    printf '%s' "$out" | jq -r '.id'
}

# --- waiting ------------------------------------------------------------------

SMOKE_TIMEOUT=${SMOKE_TIMEOUT:-300}

smoke::_await() {
    local id=$1 waited=0 state='' reason=''

    while (( waited < SMOKE_TIMEOUT )); do
        local json
        json=$(agents::_rest GET "/app/rest/builds/id:$id?fields=state,status,waitReason" 2>/dev/null) || true
        state=$(printf '%s' "$json" | jq -r '.state // ""')
        [[ $state == finished ]] && return 0

        # Why it is not running yet is far more useful than how long it has been
        # not running for.
        reason=$(printf '%s' "$json" | jq -r '.waitReason // ""')
        sleep 3; waited=$(( waited + 3 ))
        if (( waited % 15 == 0 )); then
            ui::note "  $state${reason:+ — $reason}… ${waited}s"
        fi
    done

    ui::err "The build did not finish within ${SMOKE_TIMEOUT}s (last state: ${state:-unknown})."
    [[ -n $reason ]] && ui::note "  TeamCity says: $reason"
    ui::note 'Raise it with  SMOKE_TIMEOUT=600  if this machine is simply slow.'
    return 1
}

# --- the assertions that matter -------------------------------------------------

smoke::_assert() {
    local id=$1 marker=$2

    local json
    json=$(agents::_rest GET \
        "/app/rest/builds/id:$id?fields=id,status,statusText,agent(name),startDate,finishDate" 2>/dev/null)

    local status agent
    status=$(printf '%s' "$json" | jq -r '.status // "UNKNOWN"')
    agent=$(printf '%s' "$json" | jq -r '.agent.name // "unknown"')

    if [[ $status != SUCCESS ]]; then
        ui::blank
        ui::err "The build finished $status on $agent."
        ui::note "  $(printf '%s' "$json" | jq -r '.statusText // ""')"
        ui::note "See it at $(conf::url)/build/$id"
        return 1
    fi

    # Status is TeamCity's opinion; the log is the evidence. A step that never
    # executed can still leave a build reporting success, and only the marker
    # this run generated distinguishes the two.
    local log
    log=$(agents::_rest_raw "/downloadBuildLog.html?buildId=$id" 2>/dev/null) || true
    if [[ $log != *"$marker"* ]]; then
        ui::blank
        ui::err 'The build reported success but its step produced no output.'
        ui::note "The marker '$marker' is absent from the build log, so the"
        ui::note 'command did not actually run on the agent.'
        return 1
    fi

    local arch
    arch=$(printf '%s' "$log" | grep -oE '(Linux|Darwin) (aarch64|arm64|x86_64)' | head -1)

    ui::blank
    ui::ok "Build #$id succeeded on $agent${arch:+ ($arch)}."
    ui::note 'The step ran and its output is in the build log — not just a green status.'
}

# --- cleanup ------------------------------------------------------------------

smoke::_cleanup() {
    if agents::_rest DELETE "/app/rest/projects/id:$SMOKE_PROJECT_ID" >/dev/null 2>&1; then
        ui::note 'Removed the smoke-test project.'
    fi
}

smoke::_cleanup_quiet() {
    agents::_rest DELETE "/app/rest/projects/id:$SMOKE_PROJECT_ID" >/dev/null 2>&1 || true
}
