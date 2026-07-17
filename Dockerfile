# Pinned to Elixir 1.17.3 on OTP 26 to match the release CI
# (.github/workflows/release.yml: ELIXIR_VERSION 1.17.3, OTP_VERSION 26.2.5).
# The floating `elixir:1.17-alpine` tag tracks OTP 27, which breaks
# `mix release` for this project (TypedStruct/Decimal "already compiled"
# dep-walk bug) and is incompatible with the erlexec 2.0.6 pin in mix.exs.
FROM elixir:1.17.3-otp-26-alpine AS builder

RUN apk add --no-cache build-base git

WORKDIR /app

# Compile-time paths are baked against HOME: config.exs uses
# `Path.expand("~/.osa")` and several modules resolve `System.user_home!()`
# in module attributes (e.g. budget.ex, onboarding.ex). Bake them against the
# SAME HOME the runtime container uses so runtime path resolution, filesystem
# permissions, and the mounted data volume all agree. See the runner stage.
ENV HOME=/home/osa
RUN mkdir -p /home/osa

COPY mix.exs mix.lock ./
RUN mix local.hex --force && mix local.rebar --force
RUN mix deps.get --only prod
RUN MIX_ENV=prod mix deps.compile

COPY config config
COPY lib lib
COPY priv priv
COPY rel rel
COPY VERSION ./

RUN MIX_ENV=prod mix compile
RUN MIX_ENV=prod mix release osagent

FROM alpine:3.20 AS runner

RUN apk add --no-cache libstdc++ openssl ncurses-libs
RUN addgroup -S osa && adduser -S -h /home/osa -G osa osa

WORKDIR /app

# Must match the builder HOME so the baked ~/.osa paths resolve identically.
ENV HOME=/home/osa
ENV MIX_ENV=prod

COPY --from=builder /app/_build/prod/rel/osagent ./

# Pre-create the data dir owned by the non-root runtime user. This is the
# path baked at build time (~/.osa == /home/osa/.osa) and the target of the
# compose named volume, so the mount inherits osa ownership and is writable.
RUN mkdir -p /home/osa/.osa \
  && chown -R osa:osa /app /home/osa
USER osa

EXPOSE 9089
# Busybox wget (Alpine) does not support GNU flags like --no-verbose/--tries,
# and --spider issues a HEAD the GET-only /health route rejects. Use a plain
# quiet GET discarded to /dev/null.
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD wget -q -O /dev/null http://localhost:9089/health || exit 1

CMD ["bin/osagent", "serve"]
