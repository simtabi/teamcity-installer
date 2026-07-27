# TeamCity Installer
#
# A thin wrapper over ./tc, plus the things make is genuinely better at: fixing
# file modes after a checkout that dropped them, and composing the check gates.
#
# Every target that runs ./tc depends on `perms`, so a fresh clone works without
# anyone first reading about chmod. That matters most on Windows-mounted
# filesystems, which do not carry the executable bit at all.

SHELL := /bin/sh
TC    := ./tc

.DEFAULT_GOAL := help
.PHONY: help perms up down start stop restart status logs journal token doctor \
        verify verify-deep preflight install reconfigure agents authorize \
        backup restore upgrade reset lint test check clean

## help: list the targets
help:
	@printf 'TeamCity Installer\n\n'
	@grep -E '^## ' $(MAKEFILE_LIST) \
	  | sed -e 's/^## //' \
	  | awk -F': *' '{ printf "  \033[1m%-14s\033[0m %s\n", $$1, $$2 }'
	@printf '\nEverything runs in containers; nothing is installed on this machine.\n'

## perms: restore executable bits and strip CRLF line endings
perms:
	@chmod +x $(TC) 2>/dev/null || true
	@chmod +x console/lib/*.sh stack/init/*.sh 2>/dev/null || true
	@# A Windows checkout can leave CR characters that break the shebang; the
	@# resulting "bad interpreter" error never mentions line endings.
	@for f in $(TC) console/lib/*.sh console/tests/*.bats stack/init/*.sh; do \
	    [ -f "$$f" ] || continue; \
	    if od -c "$$f" 2>/dev/null | grep -q '\\r'; then \
	        printf 'fixing CRLF: %s\n' "$$f"; \
	        tr -d '\r' < "$$f" > "$$f.tmp" && mv "$$f.tmp" "$$f"; \
	        chmod +x "$$f" 2>/dev/null || true; \
	    fi; \
	done
	@printf 'permissions and line endings ok\n'

## install: run the guided setup
install: perms
	@$(TC) install

## up: start the stack
up start: perms
	@$(TC) up

## down: stop the stack, keeping all data
down stop: perms
	@$(TC) down

## restart: recreate containers and start again
restart: perms
	@$(TC) restart

## status: container health, ports and uptime
status: perms
	@$(TC) status

## logs: follow container logs (make logs SERVICE=server)
logs: perms
	@$(TC) logs $(SERVICE)

## journal: this console's own logs (make journal TOOL=stack)
journal: perms
	@$(TC) journal $(TOOL)

## token: super user token for TeamCity's first-run setup
token: perms
	@$(TC) token

## doctor: diagnostics and health probes
doctor: perms
	@$(TC) doctor

## verify: live end-to-end checks against the running stack
verify: perms
	@$(TC) verify

## verify-deep: verify, including a real backup round-trip
verify-deep: perms
	@$(TC) verify --deep

## preflight: check this machine is ready
preflight: perms
	@$(TC) preflight

## agents: list build agents
agents: perms
	@$(TC) agents

## authorize: authorize every pending agent
authorize: perms
	@$(TC) authorize

## backup: back up the stack (make backup KIND=native|logical|cold)
backup: perms
	@$(TC) backup $(or $(KIND),cold)

## restore: restore from an archive
restore: perms
	@$(TC) restore

## upgrade: move to another TeamCity version
upgrade: perms
	@$(TC) upgrade

## reset: destroy the stack and all its data
reset: perms
	@$(TC) reset

## lint: shellcheck every script
lint: perms
	@$(TC) lint

## test: the bats suite (no daemon or network needed)
test: perms
	@$(TC) test

## check: lint, test and verify — what CI runs
check: lint test verify

## clean: prune stale console images and old backups
clean: perms
	@printf 'removing console images other than the current one…\n'
	@current=$$(docker images --format '{{.Repository}}:{{.Tag}}' \
	    | grep '^teamcity-console:' | grep -v ':latest$$' | head -1); \
	 docker images --format '{{.Repository}}:{{.Tag}}' \
	    | grep '^teamcity-console:' \
	    | grep -v ":latest$$" \
	    | grep -v "^$$current$$" \
	    | xargs -r docker rmi 2>/dev/null || true
	@printf 'applying backup retention…\n'
	@$(TC) prune || true
	@printf 'done\n'
