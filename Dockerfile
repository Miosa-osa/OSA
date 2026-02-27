FROM elixir:1.17-alpine AS builder

RUN apk add --no-cache build-base git go

WORKDIR /app

COPY mix.exs mix.lock ./
RUN mix local.hex --force && mix local.rebar --force
RUN mix deps.get --only prod
RUN MIX_ENV=prod mix deps.compile

COPY config config
COPY lib lib
COPY priv priv
COPY rel rel

# Build Go tokenizer
RUN cd priv/go/tokenizer && CGO_ENABLED=0 go build -o osa-tokenizer .

RUN MIX_ENV=prod mix compile
RUN MIX_ENV=prod mix release osagent

FROM alpine:3.19 AS runner

RUN apk add --no-cache libstdc++ openssl ncurses-libs

WORKDIR /app

COPY --from=builder /app/_build/prod/rel/osagent ./

ENV MIX_ENV=prod

CMD ["bin/osagent", "serve"]
