FROM elixir:1.17-alpine AS builder

RUN apk add --no-cache build-base git

WORKDIR /app

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

FROM alpine:3.19 AS runner

RUN apk add --no-cache libstdc++ openssl ncurses-libs
RUN addgroup -S osa && adduser -S osa -G osa

WORKDIR /app

COPY --from=builder /app/_build/prod/rel/osagent ./
RUN chown -R osa:osa /app
USER osa

ENV MIX_ENV=prod

EXPOSE 9089
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD wget --no-verbose --tries=1 --spider http://localhost:9089/health || exit 1

CMD ["bin/osagent", "serve"]
