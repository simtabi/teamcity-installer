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
.PHONY: help perms up down start stop restart status logs journal token admin \
        shell open doctor verify verify-deep preflight install reconfigure \
        agents authorize backup restore prune upgrade reset lint test check \
        users user-show user-passwd smoke \
        drift clean

## help: list the targets
help:
	@printf 'TeamCity Installer\n\n'
	@grep -E '^## ' $(MAKEFILE_LIST) \
	  | sed -e 's/^## //' \
	  | awk '{ i = index($$0, ":"); \
	           name = substr($$0, 1, i - 1); \
	           desc = substr($$0, i + 1); \
	           sub(/^ +/, "", desc); \
	           printf "  \033[1m%-14s\033[0m %s\n", name, desc }'
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

## up: start the stack (alias: start)
up start: perms
	@$(TC) up

## down: stop the stack, keeping all data (alias: stop)
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

## admin: create the first administrator account
admin: perms
	@$(TC) admin

## users: list every account, and who can administer
users: perms
	@$(TC) users

## user-show: one account in detail (make user-show USER=admin)
user-show: perms
	@$(TC) users show $(USER)

## user-passwd: set a password, works when nobody knows one (USER=admin)
user-passwd: perms
	@$(TC) users passwd $(USER)

## shell: open a shell in a container (make shell SERVICE=server)
shell: perms
	@$(TC) shell $(SERVICE)

## open: print the TeamCity URL
open: perms
	@$(TC) open

## reconfigure: change settings, keeping all data
reconfigure: perms
	@$(TC) reconfigure

## doctor: diagnostics and health probes
doctor: perms
	@$(TC) doctor

## verify: live end-to-end checks against the running stack
verify: perms
	@$(TC) verify

## smoke: run a throwaway build and prove its step executed
smoke: perms
	@$(TC) smoke

## verify-deep: verify, with no time limit on the backup check
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

## backup: back up the stack (make backup KIND=native|logical|cold|list)
backup: perms
	@$(TC) backup $(or $(KIND),cold)

## restore: restore from an archive
restore: perms
	@$(TC) restore

## prune: apply backup retention (TC_BACKUP_KEEP)
prune: perms
	@$(TC) prune

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

## check: lint, test, verify, and no tracked file changed — what CI runs
check: perms
	@# Snapshot the tree, run the gates, compare.
	@#
	@# The behavioural checks only cover what someone thought to check. A stray
	@# edit once left a real local timezone in the tracked stack/.env.example —
	@# a file every new user is handed — and make check stayed green throughout,
	@# because nothing was looking at whether files had moved.
	@#
	@# Comparing before and after catches side effects nobody predicted, while
	@# leaving your own in-progress edits alone: only changes the run itself
	@# causes are failures.
	@# Temp files rather than process substitution: SHELL is /bin/sh here, and
	@# <(...) is a bashism that fails on a POSIX shell.
	@b=$$(mktemp); a=$$(mktemp); \
	 git status --porcelain 2>/dev/null | sort > "$$b" || true; \
	 $(MAKE) --no-print-directory lint test verify; rc=$$?; \
	 git status --porcelain 2>/dev/null | sort > "$$a" || true; \
	 if [ $$rc -ne 0 ]; then rm -f "$$b" "$$a"; exit $$rc; fi; \
	 if ! cmp -s "$$b" "$$a"; then \
	     printf '\n\033[38;5;203merror\033[0m   running the checks modified tracked files:\n'; \
	     diff "$$b" "$$a" | grep -E '^[<>]' | sed 's/^/        /'; \
	     printf '        Nothing here should write to a tracked file.\n'; \
	     rm -f "$$b" "$$a"; exit 1; \
	 fi; \
	 rm -f "$$b" "$$a"; \
	 printf '\n\033[38;5;42mok\033[0m      lint, tests, live checks, and no tracked file moved.\n'

## drift: check the working tree matches the last commit
drift: perms
	@if [ -n "$$(git status --porcelain 2>/dev/null)" ]; then \
	    printf 'uncommitted changes:\n'; git status --short; exit 1; \
	 else printf 'working tree is clean\n'; fi

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
