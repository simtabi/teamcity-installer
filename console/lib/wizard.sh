#!/usr/bin/env bash
#
# wizard.sh — guided first-run setup.
#
# Every answer is validated at the prompt, and the whole set is shown for review
# before a single container is created. Nothing is written until the user
# confirms the summary.

wizard::run() {
    ui::scope wizard
    if conf::exists; then
        wizard::_existing || return 0
    fi

    ui::head 'Guided setup'
    ui::note 'Enter accepts the value shown. Everything can be changed later.'

    wizard::_ask_identity
    wizard::_ask_database
    wizard::_ask_resources
    wizard::_ask_agents

    # One secret per stack, generated once and reused on reconfigure so agents
    # already holding it stay authorized.
    if [[ $TC_AGENT_AUTO_AUTHORIZE == 1 && -z $TC_AGENT_AUTH_TOKEN ]]; then
        TC_AGENT_AUTH_TOKEN=$(validate::gen_password)
    elif [[ $TC_AGENT_AUTO_AUTHORIZE != 1 ]]; then
        TC_AGENT_AUTH_TOKEN=''
    fi

    wizard::_summary || { ui::note 'Nothing was written.'; return 1; }

    conf::save
    ui::ok "Wrote $ENV_FILE"

    conf::lock; trap conf::unlock RETURN
    render::compose || return 1
    ui::ok "Wrote $COMPOSE_FILE"

    ui::blank
    if ui::confirm 'Start the stack now?' yes; then
        stack::up || return 1
        wizard::_next_steps
    else
        ui::note 'Start it later from the menu, or with:  ./tc up'
    fi
}

# --- reconfigure guard --------------------------------------------------------

wizard::_existing() {
    conf::load
    ui::warn "A stack named '$TC_STACK' is already configured."

    local choice
    choice=$(ui::menu 'What would you like to do?' \
        'Reconfigure|change settings, keep all existing data' \
        'Cancel|leave everything as it is' \
        'Reset|destroy this stack and start over') || return 1

    case $choice in
        Reconfigure) ui::note 'Current values are prefilled; press enter to keep each.'; return 0 ;;
        Reset)       stack::reset && return 0 || return 1 ;;
        *)           return 1 ;;
    esac
}

# --- questions ----------------------------------------------------------------

wizard::_ask_identity() {
    ui::head 'Identity'

    TC_STACK=$(ui::ask 'Stack name' "$TC_STACK" validate::stack_name)
    TC_VERSION=$(wizard::_ask_version)

    # Offer the next free port rather than making the user discover the clash.
    local suggested=$TC_PORT
    if validate::_host_port_listening "$TC_PORT"; then
        suggested=$(validate::next_free_port "$TC_PORT")
        ui::warn "Port $TC_PORT is in use; suggesting $suggested."
    fi
    TC_PORT=$(ui::ask 'HTTP port' "$suggested" validate::port)

    TC_TZ=$(ui::ask 'Timezone' "$TC_TZ" validate::timezone)
    ui::note 'The agent image hardcodes Europe/London; this overrides it.'
}

wizard::_ask_version() {
    local -a versions
    mapfile -t versions < <(validate::available_versions 2>/dev/null | head -12)

    if (( ${#versions[@]} == 0 )); then
        ui::warn 'Could not list versions from Docker Hub; enter one manually.'
        ui::ask 'TeamCity version' "$TC_VERSION" validate::tc_version
        return
    fi

    # Keep the configured version at the top even if it is not in the newest 12.
    local -a options=("$TC_VERSION")
    local v
    for v in "${versions[@]}"; do [[ $v == "$TC_VERSION" ]] || options+=("$v"); done

    local picked
    picked=$(ui::choose 'TeamCity version (only tags with an image for this architecture)' \
        "${options[@]}") || picked=$TC_VERSION
    printf '%s' "$picked"
}

wizard::_ask_database() {
    ui::head 'Database'

    local choice
    choice=$(ui::menu 'Which database?' \
        'PostgreSQL|a dedicated container, configured for you' \
        'Bundled|HSQLDB inside the server — evaluation only') || return 1

    if [[ $choice == Bundled ]]; then
        TC_DB=hsqldb
        ui::warn 'JetBrains support the bundled database for evaluation only.'
        ui::note 'It is fine for a throwaway trial and a poor choice for real work.'
        return 0
    fi

    TC_DB=postgres
    TC_PG_DB=$(ui::ask 'Database name' "$TC_PG_DB" validate::db_identifier)
    TC_PG_USER=$(ui::ask 'Database user' "$TC_PG_USER" validate::db_identifier)

    local generated; generated=$(validate::gen_password)
    [[ -n $TC_PG_PASSWORD ]] && generated=$TC_PG_PASSWORD
    TC_PG_PASSWORD=$(ui::secret 'Database password' "$generated" validate::db_password)

    ui::note 'The driver and connection settings are seeded automatically, so'
    ui::note "TeamCity's setup wizard will skip the database step."
}

wizard::_ask_resources() {
    ui::head 'Resources'
    TC_MEM_OPTS=$(ui::ask 'Server JVM options' "$TC_MEM_OPTS" validate::mem_opts)
}

wizard::_ask_agents() {
    ui::head 'Build agents'
    ui::note "TeamCity's free Professional licence includes $TC_FREE_AGENTS agents, all authorized."

    TC_AGENTS=$(ui::ask 'How many agents' "$TC_AGENTS" validate::agent_count)

    if (( TC_AGENTS == 0 )); then
        ui::note 'No agents. The server will run, but nothing can build.'
        return 0
    fi

    local image
    image=$(ui::menu 'Agent image' \
        'Full|git, .NET, Perforce, Docker CLI — the usual choice' \
        'Minimal|JRE only; you install build tools yourself') || return 1
    TC_AGENT_IMAGE=$([[ $image == Minimal ]] && echo minimal || echo full)

    if ui::confirm 'Authorize agents automatically when they connect?' yes; then
        TC_AGENT_AUTO_AUTHORIZE=1
        ui::note 'Agents will authorize themselves with a shared secret, so they'
        ui::note 'can take builds immediately instead of waiting in Unauthorized.'
        ui::note 'This bypasses a step TeamCity normally puts behind a login, so'
        ui::note 'it suits a localhost stack rather than a public server.'
    else
        TC_AGENT_AUTO_AUTHORIZE=0
        ui::note 'Agents will need approving via  Agents → Authorize.'
    fi

    local docker_mode
    docker_mode=$(ui::menu 'Can agents run Docker builds?' \
        'No|simplest and safest' \
        'Docker-in-Docker|isolated inner daemon; needs a privileged container' \
        'Host socket|shares the host daemon; lighter, but far more trusting') || return 1

    case $docker_mode in
        Docker-in-Docker)
            TC_AGENT_DOCKER=dind
            TC_AGENT_IMAGE=full
            ui::warn 'Privileged containers can escape to the Docker VM.'
            ui::note 'Each agent gets its own /var/lib/docker volume so layers survive restarts.'
            ;;
        'Host socket')
            TC_AGENT_DOCKER=socket
            ui::warn 'Any build will be able to control the host Docker daemon.'
            ui::note 'That is root-equivalent on the VM. Only do this with builds you trust.'
            ;;
        *) TC_AGENT_DOCKER=none ;;
    esac
}

# --- review -------------------------------------------------------------------

wizard::_summary() {
    ui::head 'Review'

    local db_line agent_line docker_line
    if [[ $TC_DB == postgres ]]; then
        db_line="PostgreSQL $TC_PG_VERSION — db '$TC_PG_DB', user '$TC_PG_USER'"
    else
        db_line='Bundled HSQLDB (evaluation only)'
    fi

    case $TC_AGENT_DOCKER in
        dind)   docker_line='Docker-in-Docker (privileged)' ;;
        socket) docker_line='host Docker socket' ;;
        *)      docker_line='no Docker access' ;;
    esac
    agent_line="$TC_AGENTS × $TC_AGENT_IMAGE, $docker_line"
    local auth_line='manual approval via Agents → Authorize'
    [[ $TC_AGENT_AUTO_AUTHORIZE == 1 ]] && auth_line='automatic on first connect'

    # Tab-delimited, not comma: two of these values contain commas ("… db 'x',
    # user 'y'" and "3 × full, no Docker access"), and a comma separator split
    # them across columns in the one table a user reads most carefully.
    {
        printf 'SETTING\tVALUE\n'
        printf 'Stack\t%s\n'         "$TC_STACK"
        printf 'Version\t%s\n'       "$TC_VERSION"
        printf 'URL\t%s\n'           "$(conf::url)"
        printf 'Timezone\t%s\n'      "$TC_TZ"
        printf 'Database\t%s\n'      "$db_line"
        printf 'JVM\t%s\n'           "$TC_MEM_OPTS"
        printf 'Agents\t%s\n'        "$agent_line"
        printf 'Authorization\t%s\n' "$auth_line"
        printf 'Storage\t%s\n'       'named Docker volumes (nothing on the host filesystem)'
    } | column -t -s "$(printf '\t')" >&2

    ui::blank
    ui::confirm 'Create this stack?' yes
}

wizard::_next_steps() {
    ui::head 'Next steps'
    ui::note "1. Open $(conf::url) and complete TeamCity's setup:"
    ui::note '   accept the licence, then create the administrator account.'
    [[ $TC_DB == postgres ]] \
        && ui::note '   The database step is already done and will not be shown.'
    if [[ $TC_AGENT_AUTO_AUTHORIZE == 1 ]]; then
        ui::note '2. Nothing else — the agents authorize themselves and are ready to build.'
    else
        ui::note '2. Come back here and run  Agents → Authorize  so your agents'
        ui::note '   can start taking builds.'
    fi
}
