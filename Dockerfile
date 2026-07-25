# --- Build stage: fully static binary against musl on Alpine ----------------
FROM crystallang/crystal:1.21.0-alpine AS build

# Static versions of the libraries the Crystal stdlib links against.
RUN apk add --no-cache --update \
      openssl-libs-static \
      zlib-static \
      yaml-static \
      pcre2-dev

WORKDIR /app

# Cache dependencies separately from source.
COPY shard.yml shard.lock ./
RUN shards install --production --skip-postinstall

COPY src ./src
COPY public ./public

# --production keeps dev deps out; --static links musl statically;
# --no-debug drops debug info; strip removes the symbol table.
RUN shards build --release --production --no-debug --static && \
    strip bin/motivators

# --- Final stage: nothing but the binary and the assets --------------------
FROM scratch

ENV KEMAL_ENV=production
WORKDIR /app
COPY --from=build /app/bin/motivators ./motivators
COPY --from=build /app/public ./public

EXPOSE 3000
ENTRYPOINT ["/app/motivators"]
