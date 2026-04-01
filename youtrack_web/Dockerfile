FROM elixir:1.19 AS build

RUN apt-get update \
    && apt-get install -y --no-install-recommends build-essential git curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV=prod
WORKDIR /app

# Copy full repository because the Phoenix app has a path dependency on ../youtrack.
COPY . .

WORKDIR /app/youtrack_web
RUN mix deps.get --only prod
RUN mix deps.compile
RUN mix assets.deploy
RUN mix compile
RUN mix release

FROM debian:bookworm-slim AS runner

RUN apt-get update \
    && apt-get install -y --no-install-recommends libstdc++6 openssl libncurses6 sqlite3 ca-certificates \
    && rm -rf /var/lib/apt/lists/*

ENV LANG=C.UTF-8
ENV MIX_ENV=prod
ENV PHX_SERVER=true

WORKDIR /app

COPY --from=build /app/youtrack_web/_build/prod/rel/youtrack_web ./

EXPOSE 4000

CMD ["bin/youtrack_web", "start"]
