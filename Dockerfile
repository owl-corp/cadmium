# syntax=docker/dockerfile:1
#
# Cadmium agent image: a self-contained `mix release` on slim Debian.
#
#   docker build -t cadmium:dev .
#
# Builder and runtime must be the same Debian release (the release bundles ERTS,
# which links against the builder's glibc/openssl/ncurses). Available builder tags:
# https://hub.docker.com/r/hexpm/elixir/tags?name=1.19.5-erlang-28
ARG ELIXIR_VERSION=1.19.5
ARG OTP_VERSION=28.5.0.5
ARG DEBIAN_VERSION=trixie-20260824-slim

ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"

# ---------------------------------------------------------------------------
FROM ${BUILDER_IMAGE} AS builder

# git: the heroicons dep is fetched from GitHub. build-essential: NIF-capable toolchain.
RUN apt-get update -y \
 && apt-get install -y --no-install-recommends build-essential git ca-certificates \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app

ENV MIX_ENV=prod

RUN mix local.hex --force && mix local.rebar --force

# Dependencies in their own layers: only mix.exs/mix.lock (and compile-time config)
# invalidate them, not application code.
COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

# Compile-time config is needed to compile deps; runtime.exs is copied later so that
# changing it does not recompile everything.
COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

# Downloads the tailwind and esbuild binaries pinned in config/config.exs.
RUN mix assets.setup

COPY priv priv
COPY lib lib
COPY assets assets

# Compile before assets.deploy: Tailwind scans the compiled LiveView colocated output.
RUN mix compile
RUN mix assets.deploy

COPY config/runtime.exs config/
COPY rel rel
RUN mix release

# ---------------------------------------------------------------------------
FROM ${RUNNER_IMAGE} AS runner

RUN apt-get update -y \
 && apt-get install -y --no-install-recommends \
      libstdc++6 openssl libncurses6 locales ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen \
 && locale-gen

ENV LANG=en_US.UTF-8 \
    LANGUAGE=en_US:en \
    LC_ALL=en_US.UTF-8

WORKDIR /app

# The root filesystem is meant to be read-only (see the Helm chart): the release
# writes its generated sys.config/vm.args and any crash dump under /tmp, which the
# chart backs with an emptyDir.
ENV MIX_ENV=prod \
    PHX_SERVER=true \
    PORT=4000 \
    RELEASE_TMP=/tmp \
    ERL_CRASH_DUMP=/tmp/erl_crash.dump

COPY --from=builder /app/_build/prod/rel/cadmium ./

# This image deliberately runs as root (uid 0).
#
# The agent reads the *host's* /sys/fs/cgroup and /proc through read-only hostPath
# mounts. Those trees are owned by host root, and parts of them are not world-readable
# on every distro (0600/0640 cgroup and PSI files on hardened kernels, per-pid entries
# under /proc). Being uid 0 makes us the *owner* of those files, so ordinary owner
# permission bits grant access and no Linux capability (not even CAP_DAC_READ_SEARCH)
# is needed.
#
# Root here is otherwise powerless: the chart drops ALL capabilities, forbids privilege
# escalation, mounts the root filesystem and both hostPaths read-only, applies the
# RuntimeDefault seccomp profile, and uses neither hostPID nor hostNetwork.
USER root

# http, epmd, Erlang distribution (CADMIUM_DIST_PORT, see rel/env.sh.eex)
EXPOSE 4000 4369 9100

# `start` execs the BEAM, which becomes PID 1 and shuts down cleanly on SIGTERM
# (stopping the supervision tree lets the leader release its Lease).
CMD ["/app/bin/cadmium", "start"]
