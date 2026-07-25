# --- Build stage: dynamic binary + its shared libraries --------------------
# Inspired by spider-gazelle's Dockerfile: instead of a fully static binary we
# link dynamically and ship the exact libraries `ldd` reports, so each library
# can be patched independently of the application. The final image still runs
# on `scratch` — and now as an unprivileged user.
FROM crystallang/crystal:1.21.0-alpine AS build

ARG IMAGE_UID=10001
ENV UID=$IMAGE_UID
ENV APP_USER=appuser

# git for the GitHub shard dependency; ca-certificates to copy into the image.
RUN apk add --no-cache --update git ca-certificates

# Create the unprivileged user in the builder so its /etc/passwd and /etc/group
# entries can be copied into the scratch stage (busybox adduser syntax).
RUN adduser -D -g "" -H -s /sbin/nologin -u "${UID}" "${APP_USER}"

WORKDIR /app

COPY shard.yml shard.lock ./
RUN shards install --production --skip-postinstall

COPY src ./src
COPY public ./public

# Dynamic release build (no --static), then strip the symbol table.
RUN shards build --release --production --no-debug && \
    strip bin/motivators

# Collect every shared library the binary loads, preserving absolute paths,
# into /app/deps so it can be copied wholesale into the final image.
RUN for binary in /app/bin/*; do \
      ldd "$binary" | tr -s '[:blank:]' '\n' | grep '^/' | \
      xargs -I % sh -c 'mkdir -p $(dirname "deps%"); cp "%" "deps%";'; \
    done

# --- Final stage: scratch, unprivileged, only what runs --------------------
FROM scratch

ENV KEMAL_ENV=production
ENV SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt

# User identity, hosts resolution and CA certificates.
COPY --from=build /etc/passwd /etc/passwd
COPY --from=build /etc/group /etc/group
COPY --from=build /etc/hosts /etc/hosts
COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/

# The shared libraries, then the binary and the static assets.
COPY --from=build /app/deps /
COPY --from=build /app/bin/motivators /motivators
COPY --from=build /app/public /public

USER appuser:appuser
EXPOSE 3000
ENTRYPOINT ["/motivators"]
CMD ["-b", "0.0.0.0", "-p", "3000"]
