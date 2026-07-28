#!/usr/bin/env bash
#
# stack.sh — lifecycle: up, down, restart, status, logs.

# Compose is always addressed explicitly. Left implicit, the project name comes
# from the directory basename and the env file from wherever compose decides to
# look, which differs between invocation paths.
# The choke point every compose call passes through, so it is also where the
# command actually executed gets recorded. Reconstructing a failure from prose is
# guesswork; reconstructing it from the exact argv is not.
stack::compose() {
    log::cmd stack.compose "docker compose $*"
    local rc=0
    docker compose \
        --file "$COMPOSE_FILE" \
        --project-directory "$STACK_DIR" \
        --env-file "$ENV_FILE" \
        "$@" || rc=$?
    (( rc == 0 )) || log::warn stack.compose "compose $1 exited $rc"
    return $rc
}

# Configuration is the source of truth; the compose file is derived from it and
# regenerated on demand. Requiring both here would make `./tc up` fail on a
# freshly written .env, or after someone deletes the generated file.
stack::installed() { [[ -f $ENV_FILE ]]; }

# Resolve a service to its container id. Guessing compose's "<project>-<service>-1"
# naming works today and is not a contract; asking compose costs one call and
# cannot drift.
stack::container() {
    stack::compose ps --all --quiet "$1" 2>/dev/null | head -1
}

stack::ensure_rendered() {
    stack::installed || return 1
    [[ -f $COMPOSE_FILE ]] && return 0
    render::compose
}

# --- state --------------------------------------------------------------------

# running | partial | stopped | absent
stack::state() {
    stack::installed || { printf 'absent'; return; }
    [[ -f $COMPOSE_FILE ]] || { printf 'stopped'; return; }

    local total running
    total=$(stack::compose ps --all --services 2>/dev/null | grep -cv '^datadir-init$' || echo 0)
    running=$(stack::compose ps --services --status running 2>/dev/null | wc -l | tr -d ' ')

    if (( running == 0 )); then printf 'stopped'
    elif (( running >= total )); then printf 'running'
    else printf 'partial'
    fi
}

stack::_probe() {
    curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
        "http://host.docker.internal:$TC_PORT$1" 2>/dev/null || printf '000'
}

# ready | setup | starting
#
# A plain "is it 200?" check is wrong for the first run, which is the moment it
# matters most. Until the licence is accepted and an administrator exists,
# TeamCity answers *503* on / and /login.html and serves a maintenance page;
# only /mnt returns 200. Treating that as "not up" means the first ./tc up waits
# out its whole timeout and reports failure at a server that is running fine and
# waiting for the user.
stack::server_state() {
    case $(stack::_probe /login.html) in
        200) printf 'ready' ;;
        000) printf 'starting' ;;
        *)
            if [[ $(stack::_probe /mnt) == 200 ]]; then printf 'setup'
            else printf 'starting'
            fi ;;
    esac
}

stack::server_ready() { [[ $(stack::server_state) == ready ]]; }

# Up enough to talk to, whether or not first-run setup is done.
stack::server_responding() { [[ $(stack::server_state) != starting ]]; }

# --- up -----------------------------------------------------------------------

stack::up() {
    ui::scope stack
    stack::installed || { ui::err 'No stack configured yet. Run the guided setup first.'; return 1; }

    conf::lock; trap conf::unlock RETURN
    render::compose || return 1

    ui::head "Starting $TC_STACK"

    if ! stack::compose up --detach --remove-orphans; then
        ui::err 'Compose failed to bring the stack up.'
        ui::note 'Run  ./tc doctor  for container states and the server log tail.'
        return 1
    fi

    stack::_await_ready
}

stack::_await_ready() {
    ui::blank
    ui::info 'Waiting for TeamCity to answer on HTTP…'
    ui::note 'First boot creates the database schema and can take a few minutes.'

    local waited=0 limit=900
    while (( waited < limit )); do
        case $(stack::server_state) in
            ready)
                ui::blank
                ui::ok "TeamCity is up at $(conf::url)"
                # A server with no accounts is unusable; creating the first one
                # needs no browser, so there is no reason to leave it to a
                # follow-up step someone has to know about.
                stack::needs_first_user && admin::bootstrap
                return 0 ;;
            setup)
                ui::blank
                ui::ok "TeamCity is up at $(conf::url)"
                stack::show_super_user_token
                return 0 ;;
        esac

        # Fail fast rather than burning the full timeout on a container that has
        # already exited.
        if [[ $(stack::compose ps --services --status running 2>/dev/null | grep -c '^server$' || true) == 0 ]] \
           && (( waited > 30 )); then
            ui::blank
            ui::err 'The server container is not running.'
            stack::_tail_server 30
            return 1
        fi

        sleep 5
        waited=$(( waited + 5 ))
        (( waited % 30 == 0 )) && ui::note "still waiting… ${waited}s"
    done

    ui::warn "No HTTP response after ${limit}s."
    ui::note 'Run  ./tc doctor  to see where it got stuck.'
    return 1
}

# --- super user token ---------------------------------------------------------
#
# TeamCity's first-run maintenance page asks for a "Super User token" before it
# will show the licence agreement, and points at
# <TeamCity Server home>/logs/teamcity-server.log to find it. In a container
# that path is inside a volume, so the instruction is a dead end unless you know
# to go digging — which is exactly where a first run stalls.
#
# The token is regenerated on every server start, so only the LAST occurrence in
# the log is live.

# Pure: log text on stdin, the last token on stdout. Separated out so it can be
# unit-tested against fixture log lines — the surrounding log is full of prose
# that a looser pattern happily matches instead ("…private browser window").
stack::_parse_super_user_token() {
    grep -oE 'Super user authentication token: [0-9]+' \
        | tail -1 \
        | grep -oE '[0-9]+$'
}

stack::super_user_token() {
    docker run --rm -v "$(conf::volume logs)":/l:ro alpine:3.22 \
        sh -c "grep -h 'Super user authentication token:' /l/teamcity-server.log 2>/dev/null" 2>/dev/null \
        | stack::_parse_super_user_token
}

# Ask the server whether it actually accepts this token.
#
# Printing a number the user cannot check is not good enough: the token is
# regenerated on every server start, and this log accumulates one per start. A
# stale token produces "Incorrect token was entered. Authentication failed" on
# the maintenance page, with nothing to say which of the numbers you were given
# is the live one.
#
# The maintenance page posts { token } to /mnt/do/authenticate behind a CSRF
# check, and answers "OK" or the rejection message. Replaying that turns a guess
# into a fact. Authenticating does not consume the token — it stays valid until
# the next restart.
#
#   0  accepted        1  rejected        2  cannot tell
stack::_token_accepted() {
    local token=$1
    [[ -n $token ]] || return 2

    local base="http://host.docker.internal:$TC_PORT"

    # Past the maintenance page the token stops being a form field and becomes a
    # password: TeamCity accepts it over HTTP basic auth with an empty username.
    # Checking only the maintenance form meant the answer became "cannot confirm"
    # exactly when the server finished starting, which is not much of an answer.
    if [[ $(stack::server_state) == ready ]]; then
        local code
        code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
            -u ":$token" "$base/app/rest/server" 2>/dev/null) || return 2
        case $code in
            200) return 0 ;;
            401|403) return 1 ;;
            *) return 2 ;;
        esac
    fi

    [[ $(stack::server_state) == setup ]] || return 2
    local jar; jar=$(mktemp) || return 2
    local page csrf result

    page=$(curl -sS -c "$jar" --max-time 10 "$base/mnt" 2>/dev/null) || { rm -f "$jar"; return 2; }
    csrf=$(printf '%s' "$page" \
        | grep -oE 'name="tc-csrf-token"[^>]*content="[^"]*"' \
        | grep -oE 'content="[^"]*"' | cut -d'"' -f2 | head -1)

    result=$(curl -sS -b "$jar" --max-time 10 -X POST "$base/mnt/do/authenticate" \
        -H "X-TC-CSRF-Token: $csrf" \
        --data-urlencode "token=$token" 2>/dev/null)
    rm -f "$jar"

    case $result in
        OK*)        return 0 ;;
        *Incorrect*|*failed*) return 1 ;;
        *)          return 2 ;;
    esac
}

stack::show_super_user_token() {
    local token; token=$(stack::super_user_token)

    ui::blank
    ui::info 'TeamCity is waiting for first-run setup. In the browser:'

    if [[ -n $token ]]; then
        ui::note '  1. It will ask for a Super User token. Use this one:'
        ui::blank
        if ui::plain; then
            printf '        %s\n' "$token" >&2
        else
            gum style --foreground "$UI_ACCENT" --bold --padding '0 8' "$token" >&2
        fi
        ui::blank
        if stack::_token_accepted "$token"; then
            ui::note '     Verified against the server just now.'
        fi
        ui::note '     A new token is issued on every server start, so an older one'
        ui::note '     will be rejected. Run  ./tc token  for the current one.'
    else
        ui::warn '  1. It will ask for a Super User token, but none has been logged yet.'
        ui::note '     Wait a few seconds and run  ./tc token'
    fi

    ui::note '  2. Review and accept the licence agreement.'
    ui::note '  3. Create the administrator account.'
    [[ $TC_DB == postgres ]] \
        && ui::note '     The database step is already configured and will not be shown.'
    ui::blank
    ui::note 'Then come back and run  Agents → Authorize  so builds can run.'
}

# How many user accounts exist.
#
# A server that has finished starting reports "ready" and answers 200 on
# /login.html, but with no accounts nobody can actually sign in — the licence has
# been accepted and the first administrator has not been created. That state
# looks healthy from the outside and is the last hurdle of a first run, so it is
# worth naming rather than leaving someone at a login form with no credentials.
#
# Prints a count, or nothing when it cannot be determined.
stack::user_count() {
    local token; token=$(stack::super_user_token)
    [[ -n $token ]] || return 1
    [[ $(stack::server_state) == ready ]] || return 1

    curl -s --max-time 10 -u ":$token" \
        "http://host.docker.internal:$TC_PORT/app/rest/users" 2>/dev/null \
        | grep -oE 'count="[0-9]+"' | head -1 | grep -oE '[0-9]+'
}

# True when the server is up but has no accounts yet.
stack::needs_first_user() {
    local n; n=$(stack::user_count) || return 1
    [[ $n == 0 ]]
}

stack::first_user_hint() {
    local token; token=$(stack::super_user_token)
    ui::blank
    ui::warn 'TeamCity is running, but no user account exists yet.'
    ui::note 'Nobody can sign in until you create the first administrator.'
    ui::blank
    ui::note "  1. Open  $(conf::url)/login.html"
    ui::note '  2. Leave the username blank and use this token as the password:'
    if [[ -n $token ]]; then
        ui::blank
        if ui::plain; then
            printf '        %s\n' "$token" >&2
        else
            gum style --foreground "$UI_ACCENT" --bold --padding '0 8' "$token" >&2
        fi
        ui::blank
    else
        ui::note '     (run  ./tc token  to fetch it)'
    fi
    ui::note '  3. Administration → Users → Create user account.'
    ui::note 'Use a private window: signing in as super user replaces your session.'
}

# Standalone command: print the current token, with context.
stack::token() {
    stack::installed || { ui::err 'No stack configured.'; return 1; }

    local token; token=$(stack::super_user_token)

    if [[ -z $token ]]; then
        ui::err 'No super user token found in the server log.'
        ui::note 'The server may not have started yet. Check with:  ./tc status'
        return 1
    fi

    ui::head 'Super user token'

    # Always to stdout, in both modes, so `./tc token 2>/dev/null` is scriptable
    # from a terminal too. Under a TTY the styled copy goes to stderr as well,
    # which is chrome, not the value.
    ui::plain || gum style --foreground "$UI_ACCENT" --bold --padding '0 4' "$token" >&2
    printf '%s\n' "$token"
    ui::blank

    stack::_token_accepted "$token"
    case $? in
        0) ui::ok 'Verified — the server accepts this token right now.' ;;
        1) ui::err 'The server rejected this token.'
           ui::note 'The most likely cause is a restart since it was logged: a new'
           ui::note 'token is issued on every server start, and the old one dies.'
           ui::note 'Nothing newer is in the log, so wait a moment and try again,'
           ui::note 'or run  ./tc restart  and take the token this prints.'
           log::warn stack.token 'server rejected the extracted token'
           return 1 ;;
        *) ui::note 'Could not confirm it against the server (it may already be set up).' ;;
    esac
    ui::blank
    ui::note "Use it at $(conf::url) with an empty username."
    ui::note 'It is regenerated every time the server restarts.'
    ui::note 'It grants full administrative access — treat it like a root password.'
}

stack::_tail_server() {
    local lines=${1:-50}
    ui::blank
    ui::head "Last $lines lines from the server"
    stack::compose logs --tail "$lines" server 2>&1 | sed 's/^/  /' >&2
}

# --- down / restart -----------------------------------------------------------

stack::down() {
    ui::scope stack
    stack::installed || return 1
    conf::lock; trap conf::unlock RETURN
    ui::spin "Stopping $TC_STACK" -- stack::compose stop
    ui::ok 'Stopped. All data is preserved in its volumes.'
}

stack::restart() {
    ui::scope stack
    stack::installed || return 1
    conf::lock; trap conf::unlock RETURN
    render::compose || return 1
    ui::spin "Restarting $TC_STACK" -- stack::compose up --detach --remove-orphans --force-recreate
    stack::_await_ready
}

# --- status -------------------------------------------------------------------

stack::status() {
    ui::scope stack
    if ! stack::installed; then
        ui::warn 'No stack configured. Run the guided setup.'
        return 1
    fi
    stack::ensure_rendered || return 1

    ui::head "Status — $TC_STACK"

    local json
    json=$(stack::compose ps --all --format json 2>/dev/null || true)

    if [[ -z $json ]]; then
        ui::note 'No containers exist yet. The stack has never been started.'
        return 1
    fi

    {
        printf 'SERVICE,STATE,HEALTH,RESTARTS,PORTS\n'
        printf '%s\n' "$json" | jq -rs '
            (if type == "array" and (.[0] | type) == "array" then .[0] else . end)
            | .[]
            | [ .Service,
                (.State // "-"),
                (.Health // "-" | if . == "" then "-" else . end),
                (.ExitCode // 0 | tostring),
                # unique: a published port is listed once per address family,
                # so without it every mapping appears twice.
                (.Publishers // [] | map(select(.PublishedPort > 0)
                    | "\(.PublishedPort)->\(.TargetPort)") | unique | join(" ")
                    | if . == "" then "-" else . end)
              ]
            | @csv' 2>/dev/null | tr -d '"'
    } | column -t -s, >&2

    ui::blank
    case $(stack::server_state) in
        ready)
            if stack::needs_first_user; then
                ui::warn "Up at $(conf::url), but no user account exists yet — run  ./tc token"
            else
                ui::ok "HTTP ready at $(conf::url)"
            fi ;;
        setup)    ui::warn "Up at $(conf::url), waiting for first-run setup (licence and admin account)." ;;
        starting) ui::warn "No HTTP response on $(conf::url)" ;;
    esac

    # Meant to be scriptable: exit non-zero unless every container is running.
    [[ $(stack::state) == running ]]
}

# --- logs ---------------------------------------------------------------------

stack::logs() {
    stack::installed || { ui::err 'No stack configured.'; return 1; }
    stack::ensure_rendered || return 1

    local service=${1:-}

    if [[ -z $service ]]; then
        local -a services
        mapfile -t services < <(stack::compose ps --all --services 2>/dev/null)
        (( ${#services[@]} > 0 )) || { ui::err 'No services to show.'; return 1; }
        service=$(ui::choose 'Which service?' 'all' "${services[@]}") || return 0
    fi

    ui::note 'Ctrl-C stops following and returns to the menu.'
    ui::blank

    # Without trapping INT here, Ctrl-C would take down the console itself rather
    # than just the log follow. The previous handler is not saved and eval'd
    # back — nothing else sets one, and eval-ing `trap -p` output is a needless
    # way to execute a string.
    trap ':' INT

    if [[ $service == all ]]; then
        stack::compose logs --follow --tail 100 || true
    else
        stack::compose logs --follow --tail 200 "$service" || true
    fi

    trap - INT
    return 0
}

# --- shell --------------------------------------------------------------------

stack::shell() {
    stack::installed || { ui::err 'No stack configured.'; return 1; }
    stack::ensure_rendered || return 1

    local -a services
    mapfile -t services < <(stack::compose ps --services --status running 2>/dev/null)
    (( ${#services[@]} > 0 )) || { ui::err 'Nothing is running.'; return 1; }

    local service
    service=$(ui::choose 'Shell into which container?' "${services[@]}") || return 0

    ui::note "Opening a shell in $service. Type 'exit' to return."
    stack::compose exec "$service" bash 2>/dev/null \
        || stack::compose exec "$service" sh \
        || ui::err "Could not open a shell in $service."
    return 0
}

# --- browser ------------------------------------------------------------------

stack::open_url() {
    local url; url=$(conf::url)
    # The console cannot open a browser on the host — it is a container. Printing
    # the URL is honest; pretending to launch something would not be.
    ui::blank
    ui::info 'TeamCity is at:'
    if ui::plain; then
        printf '%s\n' "$url" >&2
    else
        gum style --foreground "$UI_INFO" --bold --padding '0 4' "$url" >&2
    fi
    ui::note 'Cmd-click the URL, or copy it into a browser.'
    stack::server_ready || ui::warn 'It is not answering yet — start the stack first.'
}
