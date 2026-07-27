#!/usr/bin/env bats
#
# Super user token extraction.
#
# TeamCity prints the token to teamcity-server.log surrounded by prose, and
# rotates it on every restart. An earlier implementation grepped for any run of
# 8+ alphanumerics and took the last match, which returns "browser" from the
# line that sits immediately beside the real token:
#
#   Administrator can login from web UI using super user authentication token
#   (better use a private browser window)
#
# The fixtures reproduce the exact shape TeamCity 2026.1.3 logs, with invented
# token values — never paste a real one into a repository, expired or not.

load helper

setup() {
    load_libs
    # shellcheck disable=SC1090
    source "$LIB/stack.sh"
}

fixture() {
    cat <<'LOG'
[2026-07-27 19:41:30,398]   INFO -  jetbrains.buildServer.STARTUP - Administrator can login from web UI using super user authentication token (better use a private browser window)
[2026-07-27 19:41:30,399]   INFO -   jetbrains.buildServer.SERVER - Super user authentication token: 8929098223003739163 (use empty username with the token as the password to access the server)
LOG
}

@test "extracts the token, not the surrounding prose" {
    run bash -c "$(declare -f fixture stack::_parse_super_user_token); fixture | stack::_parse_super_user_token"
    [ "$status" -eq 0 ]
    [ "$output" = '8929098223003739163' ]
}

@test "takes the most recent token when the server has restarted" {
    run bash -c "$(declare -f stack::_parse_super_user_token); printf '%s\n' \
        'Super user authentication token: 1111111111111111111 (use empty username)' \
        'Super user authentication token: 2222222222222222222 (use empty username)' \
        'Super user authentication token: 3333333333333333333 (use empty username)' \
        | stack::_parse_super_user_token"
    [ "$output" = '3333333333333333333' ]
}

@test "emits nothing when no token has been logged" {
    run bash -c "$(declare -f stack::_parse_super_user_token); printf '%s\n' \
        'INFO - jetbrains.buildServer.STARTUP - Current stage: Looking for the TeamCity Data Directory' \
        | stack::_parse_super_user_token"
    [ -z "$output" ]
}

@test "is not fooled by the word token appearing elsewhere" {
    run bash -c "$(declare -f stack::_parse_super_user_token); printf '%s\n' \
        'INFO - some access token 12345678 was revoked' \
        'INFO - authentication token rotation scheduled' \
        | stack::_parse_super_user_token"
    [ -z "$output" ]
}

# The failure this file was extended for: the token rotates on every server
# start, so the log accumulates one per start and only the last is live. An
# older one is rejected with "Incorrect token was entered. Authentication
# failed", which says nothing about which number to use instead.
@test "a log spanning several server starts yields only the newest token" {
    run bash -c "$(declare -f stack::_parse_super_user_token); printf '%s\n' \
        'Super user authentication token: 1000000000000000001 (use empty username)' \
        'INFO - Current stage: TeamCity server is shutting down' \
        'INFO - Current stage: Looking for the TeamCity Data Directory' \
        'Super user authentication token: 2000000000000000002 (use empty username)' \
        | stack::_parse_super_user_token"
    [ "$output" = '2000000000000000002' ]
}

@test "a starting server yields 'cannot tell', never a guess" {
    # Nothing to ask yet, so it must not claim either outcome.
    stack::server_state() { printf 'starting'; }
    run stack::_token_accepted '123456'
    [ "$status" -eq 2 ]
}

# Past the maintenance page the token becomes a basic-auth password, so the
# check follows it there rather than giving up — "could not confirm" is a poor
# answer at exactly the moment the server finishes starting.
@test "a ready server is checked over REST" {
    stack::server_state() { printf 'ready'; }

    curl() { printf '200'; }                       # server accepts it
    run stack::_token_accepted 'good-token'
    [ "$status" -eq 0 ]

    curl() { printf '401'; }                       # server rejects it
    run stack::_token_accepted 'stale-token'
    [ "$status" -eq 1 ]

    curl() { printf '503'; }                       # anything else is unknown
    run stack::_token_accepted 'unclear'
    [ "$status" -eq 2 ]
}

@test "an empty token is never reported as accepted" {
    stack::server_state() { printf 'setup'; }
    run stack::_token_accepted ''
    [ "$status" -eq 2 ]
}

@test "output is bare, so it can be piped straight into a form" {
    run bash -c "$(declare -f fixture stack::_parse_super_user_token); fixture | stack::_parse_super_user_token"
    [[ $output =~ ^[0-9]+$ ]]
}
