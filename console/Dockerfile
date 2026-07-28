# The TeamCity control console.
#
# Everything the tooling needs lives here so that nothing has to be installed on
# the host. The container drives the host's Docker daemon through a bind-mounted
# socket; it never runs TeamCity itself.

FROM alpine:3.22

# bash          - the scripts are bash, not ash (arrays, local, [[ ]])
# coreutils     - GNU stat/numfmt/sort, whose flags the scripts rely on
# ncurses       - tput, for terminal width
# gum           - the interactive UI primitives
# flock         - serialises concurrent ./tc invocations
# shellcheck    - powers `./tc lint`, so linting needs nothing on the host either
# bats          - powers `./tc test`; the suite is pure, so it needs no daemon
# git           - lets the secret-hygiene tests assert the ignore rules for real
# util-linux-misc - provides `column`, which busybox does not ship; every table
#                 in the console is formatted with it
RUN apk add --no-cache \
        bash \
        bats \
        ca-certificates \
        coreutils \
        curl \
        docker-cli \
        docker-cli-compose \
        flock \
        git \
        gum \
        gzip \
        jq \
        ncurses \
        openssl \
        shellcheck \
        tar \
        tzdata \
        util-linux-misc

COPY lib /app/lib
COPY tests /app/tests
RUN chmod +x /app/lib/*.sh

# Quiet the "gum is running in a non-interactive terminal" heuristics and keep
# colour behaviour predictable across OrbStack / Docker Desktop / plain Linux.
# The console always runs git against a bind-mounted directory it does not own —
# root inside the container, the user's uid outside — which git refuses as
# "dubious ownership". That is inherent to the design, not a symptom, so declare
# it safe rather than making every caller work around it. Via environment
# variables so no config file has to be written into the image.
ENV TERM=xterm-256color \
    TC_CONSOLE=1 \
    GIT_CONFIG_COUNT=1 \
    GIT_CONFIG_KEY_0=safe.directory \
    GIT_CONFIG_VALUE_0=*

ENTRYPOINT ["/app/lib/main.sh"]
