#!/usr/bin/env bash
#
# main.sh — entrypoint for the TeamCity control console.
#
# Runs inside the console container. The host side is ./tc, which resolves the
# Docker socket, builds this image when it changes, and execs into here.

set -Eeuo pipefail

LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# log.sh first: ui.sh routes every message through it.
# shellcheck source=log.sh
source "$LIB_DIR/log.sh"
# shellcheck source=ui.sh
source "$LIB_DIR/ui.sh"
# shellcheck source=conf.sh
source "$LIB_DIR/conf.sh"
# shellcheck source=validate.sh
source "$LIB_DIR/validate.sh"
# shellcheck source=preflight.sh
source "$LIB_DIR/preflight.sh"
# shellcheck source=render.sh
source "$LIB_DIR/render.sh"
# shellcheck source=stack.sh
source "$LIB_DIR/stack.sh"
# shellcheck source=wizard.sh
source "$LIB_DIR/wizard.sh"
# shellcheck source=agents.sh
source "$LIB_DIR/agents.sh"
# shellcheck source=backup.sh
source "$LIB_DIR/backup.sh"
# shellcheck source=upgrade.sh
source "$LIB_DIR/upgrade.sh"
# shellcheck source=doctor.sh
source "$LIB_DIR/doctor.sh"
# shellcheck source=admin.sh
source "$LIB_DIR/admin.sh"
# shellcheck source=verify.sh
source "$LIB_DIR/verify.sh"

# --- error handling -----------------------------------------------------------
#
# In the menu, an unexpected failure should say what broke and hand control back
# rather than dumping the user out of the container with a bare exit code.
#
# The trap is deliberately NOT armed for one-shot commands. A command like
# `./tc status` returns non-zero as a normal result — "the stack is not fully
# running" — and reporting that as an unexpected failure is both wrong and
# noisy. Bash cannot tell a handled non-zero return from a genuine fault, so the
# distinction is drawn by mode instead: commands print their own errors and
# propagate their exit code; only the menu gets the safety net.

TC_IN_MENU=0

main::on_error() {
    local rc=$? cmd=$BASH_COMMAND line=${BASH_LINENO[0]} src=${BASH_SOURCE[1]:-main.sh}
    ui::blank
    ui::err "Unexpected failure (exit $rc)"
    ui::note "$(basename "$src"):$line"
    ui::note "$cmd"
    log::error console.error "$(basename "$src"):$line — $cmd (exit $rc)"
}

# --- reset --------------------------------------------------------------------

stack::reset() {
    stack::installed || { ui::err 'Nothing to reset.'; return 1; }

    ui::head 'Reset'
    ui::warn "This destroys every project, build, artifact and agent token in '$TC_STACK'."
    ui::note 'Archives in backups/ are not touched.'

    ui::confirm_typed "$TC_STACK" 'There is no undo.' || return 0

    conf::lock; trap conf::unlock RETURN
    ui::spin 'Removing containers and volumes' -- stack::compose down --volumes --remove-orphans

    local -a volumes; mapfile -t volumes < <(render::volume_names)
    local vol
    for vol in "${volumes[@]}"; do docker volume rm "$vol" >/dev/null 2>&1 || true; done

    rm -f "$ENV_FILE" "$SECRETS_FILE" "$COMPOSE_FILE"

    ui::blank
    ui::ok 'Stack removed.'
    ui::note 'backups/ and the console image are untouched. Run the setup again to rebuild.'
}

# --- menu ---------------------------------------------------------------------

# The banner is redrawn after every action, so it must never wait on the network.
# It previously issued a REST call with a 20 s timeout on each redraw: with a
# token stored and the server slow or stopped, returning to the menu stalled for
# twenty seconds every time. Cached for 30 s, and with a 3 s ceiling so even a
# cache miss cannot hang the interface.
TC_AGENT_SUMMARY=''
TC_AGENT_SUMMARY_AT=0
TC_AGENT_SUMMARY_TTL=30

main::_agent_summary() {
    local now; now=$(date +%s)

    if [[ -n $TC_AGENT_SUMMARY ]] && (( now - TC_AGENT_SUMMARY_AT < TC_AGENT_SUMMARY_TTL )); then
        printf '%s' "$TC_AGENT_SUMMARY"
        return
    fi

    local summary=''
    if true; then
        local json
        if json=$(TC_REST_TIMEOUT=3 agents::_rest GET \
                '/app/rest/agents?locator=defaultFilter:false&fields=count,agent(authorized)' 2>/dev/null); then
            summary="agents $(printf '%s' "$json" | jq -r '[.agent[]? | select(.authorized)] | length')/$(printf '%s' "$json" | jq -r '.count // 0') authorized"
        fi
    fi
    [[ -n $summary ]] || summary="$TC_AGENTS agent(s) configured"

    TC_AGENT_SUMMARY=$summary
    TC_AGENT_SUMMARY_AT=$now
    printf '%s' "$summary"
}

main::status_line() {
    local state; state=$(stack::state)
    local agents='no agents'

    if [[ $state == running || $state == partial ]]; then
        agents=$(main::_agent_summary)
    elif (( TC_AGENTS > 0 )); then
        agents="$TC_AGENTS agent(s) configured"
    fi

    ui::banner "$TC_STACK" "$TC_VERSION" "$state" "$(conf::url)" "$agents"
}

# One table drives both the rendering and the dispatch. Previously the entries
# lived in a ui::menu call and the handlers in a parallel case statement, so the
# two could drift silently — and, more importantly, nothing could enumerate the
# menu to test it. Every entry here is `label|gloss|handler`, and a test asserts
# each handler is a defined function.
TC_MENU=(
    'Start|bring server, database and agents up|stack::up'
    'Stop|graceful shutdown, data preserved|stack::down'
    'Restart|recreate containers and start again|stack::restart'
    'Status|container health, ports, uptime|stack::status'
    'Logs|follow a container service|stack::logs'
    'Journal|this console-s own logs, one file per tool|log::show'
    'Agents|scale, list, authorize, prune|agents::menu'
    'Backup|back up, restore, list archives|backup::menu'
    'Upgrade|move to another TeamCity version|upgrade::run'
    'Verify|live end-to-end checks against this stack|verify::run'
    'Doctor|diagnostics and health probes|main::doctor_menu'
    'Token|super user token for first-run setup|stack::token'
    'Admin|create the first administrator account|admin::bootstrap'
    'Open|show the TeamCity URL|stack::open_url'
    'Shell|open a shell in a container|stack::shell'
    'Reconfigure|change settings, keep data|wizard::run'
    'Reset|destroy this stack and all its data|stack::reset'
    'Quit|leave the console|main::quit'
)

TC_MENU_UNINSTALLED=(
    'Install|guided setup, a few questions|wizard::run'
    'Preflight|check this machine is ready|preflight::run'
    'Quit|leave the console|main::quit'
)

main::quit() { return 0; }

# Entries whose handler paints its own screen and should not then be interrupted
# by a "press enter" prompt.
# Only submenus and the two handlers that own the terminal until the user quits
# them. Everything else ends with a visible prompt: the wizard and the log viewer
# used to be exempt, and both finished by silently redrawing the menu — the exact
# moment someone wonders whether it has hung.
main::_is_interactive_handler() {
    case $1 in
        stack::logs|stack::shell|agents::menu|backup::menu|main::doctor_menu) return 0 ;;
        *) return 1 ;;
    esac
}

main::_menu_entries() {
    if stack::installed; then printf '%s\n' "${TC_MENU[@]}"
    else printf '%s\n' "${TC_MENU_UNINSTALLED[@]}"
    fi
}

main::_handler_for() {
    local want=$1 entry
    while IFS= read -r entry; do
        [[ ${entry%%|*} == "$want" ]] && { printf '%s' "${entry##*|}"; return 0; }
    done < <(main::_menu_entries)
    return 1
}

main::menu() {
    TC_IN_MENU=1
    trap main::on_error ERR

    while true; do
        main::status_line

        local -a entries=() choices=()
        mapfile -t entries < <(main::_menu_entries)
        local entry
        for entry in "${entries[@]}"; do
            # ui::menu takes label|gloss; the handler is the third field.
            choices+=("${entry%|*}")
        done

        local header='What next?'
        stack::installed || header='Not installed yet'

        local choice
        choice=$(ui::menu "$header" "${choices[@]}") || return 0
        [[ $choice == Quit ]] && return 0

        local handler
        handler=$(main::_handler_for "$choice") || { ui::err "No handler for '$choice'."; continue; }

        ui::scope "$(main::_scope_for "${choice,,}")"
        log::info console.menu "selected: $choice -> $handler"

        # Wrapped so a failure inside an action returns to the menu rather than
        # tearing the console down.
        "$handler" || true

        main::_is_interactive_handler "$handler" || ui::pause "$choice"
    done
}

main::doctor_menu() {
    local choice
    choice=$(ui::menu 'Doctor' \
        'Diagnose|run all health probes' \
        'Export bundle|write a shareable diagnostics archive' \
        'Back|') || return 0

    case $choice in
        Diagnose)        doctor::run; ui::pause ;;
        'Export bundle') doctor::bundle; ui::pause ;;
    esac
}

# --- non-interactive ----------------------------------------------------------

main::usage() {
    cat >&2 <<'EOF'
TeamCity control console

  ./tc                     interactive menu
  ./tc install             run the guided setup
  ./tc up                  start the stack
  ./tc down                stop the stack
  ./tc restart             recreate and start
  ./tc status              container states; non-zero exit if not fully running
  ./tc agents              list agents
  ./tc authorize           authorize every pending agent
  ./tc backup [kind]       kind: native | logical | cold | list  (default cold)
  ./tc restore             restore from an archive
  ./tc prune               apply backup retention (TC_BACKUP_KEEP)
  ./tc upgrade             move to another TeamCity version
  ./tc doctor              diagnostics
  ./tc token               super user token for TeamCity's first-run setup
  ./tc admin               create the first administrator account
  ./tc shell [service]     open a shell in a running container
  ./tc open                print the TeamCity URL
  ./tc reconfigure         change settings, keeping all data
  ./tc logs [service]      container logs
  ./tc journal [tool]      this console's own logs (add 'follow' to tail)
  ./tc preflight           check this machine is ready
  ./tc reset               destroy the stack and all its data
  ./tc lint                shellcheck the console scripts
  ./tc test                run the bats suite (no daemon or network needed)
  ./tc verify [--deep]     live end-to-end checks against the running stack
  ./tc --help              this text

Two different tokens are involved, for two different jobs:

  super user token   unlocks TeamCity's first-run maintenance page (licence
                     agreement). Printed to the server log, rotates on every
                     restart, never stored.   ->  ./tc token
  access token       lets this console authorize agents over REST. You create
                     it in the TeamCity UI; it is stored in stack/.secrets.

Everything runs in containers; nothing is installed on the host.
Settings live in stack/.env.
EOF
}

main::lint() {
    local rc=0
    ui::head 'shellcheck'
    # SC1090/SC1091: sourced paths are computed at runtime.
    # SC2034: theme colours are consumed by other files in the same shell.
    shellcheck --external-sources --exclude=SC1090,SC1091,SC2034 \
        "$LIB_DIR"/*.sh "$TC_ROOT/tc" "$TC_ROOT/stack/init/seed-datadir.sh" \
        && ui::ok 'Clean.' || rc=1
    return $rc
}

main::test() {
    ui::head 'bats'
    # The suite stubs out docker and the network, so it runs anywhere the image
    # runs — no stack, no daemon, no internet.
    bats --print-output-on-failure "$LIB_DIR/../tests"
}

# Commands are the user's vocabulary; logs are organised by the subsystem that
# owns them. Without this mapping every command minted its own file and logs/
# filled with one-line status.log, lint.log, token.log … instead of the eight
# tool logs that are actually useful to read.
main::_scope_for() {
    case $1 in
        up|start|down|stop|restart|status|logs|token|shell|open) printf 'stack' ;;
        prune)                                                   printf 'backup' ;;
        agents|authorize)                                        printf 'agents' ;;
        backup|restore)                                          printf 'backup' ;;
        upgrade)                                                 printf 'upgrade' ;;
        doctor)                                                  printf 'doctor' ;;
        verify)                                                  printf 'verify' ;;
        install|reconfigure)                                     printf 'wizard' ;;
        admin)                                                   printf 'admin' ;;
        *)                                                       printf 'console' ;;
    esac
}

main::run_command() {
    local cmd=$1; shift
    ui::scope "$(main::_scope_for "$cmd")"
    log::info console.run "command: $cmd${*:+ $*}"

    # Commands that repair or replace the configuration must not be gated on it
    # being valid — that would leave a broken stack with no way out.
    case $cmd in
        install|reset|help|--help|-h|lint|test|journal|preflight) ;;
        *) conf::validate || return 1 ;;
    esac

    case $cmd in
        install)   wizard::run ;;
        up|start)  stack::up ;;
        down|stop) stack::down ;;
        restart)   stack::restart ;;
        status)    stack::status ;;
        logs)      stack::logs "${1:-all}" ;;
        agents)    agents::list ;;
        authorize) agents::authorize ;;
        backup)
            case ${1:-cold} in
                native)  backup::_native ;;
                logical) backup::_logical ;;
                cold)    backup::_cold ;;
                # Reachable from the menu since it existed, and from nowhere a
                # script could call. That is the same gap that once left shell,
                # open, reconfigure and prune menu-only: a capability the tool
                # has and cannot be asked for.
                list)    ui::scope backup; backup::list ;;
                *) ui::err "Unknown backup kind '${1}'. Use native, logical, cold or list."; return 2 ;;
            esac ;;
        restore)   backup::restore ;;
        upgrade)   upgrade::run ;;
        doctor)    doctor::run ;;
        token)     stack::token ;;
        admin)     admin::bootstrap ;;
        shell)     stack::shell "${1:-}" ;;
        open)      stack::open_url ;;
        reconfigure) wizard::run ;;
        journal)   log::show "${1:-}" "${2:-}" ;;
        prune)     ui::scope backup; backup::prune ;;
        preflight) preflight::run ;;
        reset)     stack::reset ;;
        lint)      main::lint ;;
        test)      main::test ;;
        verify)    [[ ${1:-} == --deep ]] && VERIFY_DEEP=1; verify::run ;;
        help|--help|-h) main::usage ;;
        *)         ui::err "Unknown command '$cmd'."; main::usage; return 2 ;;
    esac
}

# --- entry --------------------------------------------------------------------

main() {
    mkdir -p "$STACK_DIR" "$BACKUP_DIR" "$LOG_DIR"

    # Seed the configuration from the tracked example when it is missing, so a
    # fresh clone is usable without a separate setup step.
    conf::exists || conf::bootstrap >/dev/null 2>&1 || true

    conf::load || true
    log::info console.session "session $TC_SESSION started (${TC_ROOT})"

    if (( $# > 0 )); then
        # `|| rc=$?` keeps errexit from firing on a meaningful non-zero result
        # and lets the exit code reach the caller unchanged.
        local rc=0
        main::run_command "$@" || rc=$?
        log::write "$([[ $rc -eq 0 ]] && echo INFO || echo ERROR)" console.run "exit $rc"
        return "$rc"
    fi

    if ui::plain; then
        # No terminal: a menu would block forever waiting on stdin.
        ui::err 'No terminal attached, so there is no menu to show.'
        ui::note 'Pass a command instead, for example:  ./tc status'
        main::usage
        return 2
    fi

    main::menu
}

# Run only when executed, not when sourced. The test suite sources this file to
# enumerate the menu table and assert every entry names a real handler; without
# the guard, sourcing it would launch the console.
if [[ ${BASH_SOURCE[0]} == "${0}" ]]; then
    main "$@"
fi
