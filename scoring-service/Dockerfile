# Multi-stage build: analytics-kernel oracle + scoring service JRE 17 image.
ARG BUILD_IMAGE=docker.io/library/eclipse-temurin@sha256:e573c097106f35634857604fdfbe70a2a2bbcaa52574bca3d2025703d0df994d
ARG RUNTIME_IMAGE=docker.io/library/eclipse-temurin@sha256:24cd8eed18b5976441d27b45823490eb5e8efff4b3ecdc632e442717ea66f160
ARG RELEASE_PLATFORM=linux/amd64
FROM --platform=${RELEASE_PLATFORM} ${BUILD_IMAGE} AS build
ARG VCS_REF
ARG RELEASE_SHA=${VCS_REF}
WORKDIR /build
# Analytics kernel sources live in ../android — build context must be the repo root:
#   docker build -f scoring-service/Dockerfile .
COPY android /build/android
COPY scoring-service /build/scoring-service
WORKDIR /build/scoring-service
RUN chmod +x gradlew
RUN test "${#RELEASE_SHA}" -eq 40 && printf '%s\n' "$RELEASE_SHA" | grep -Eq '^[0-9a-f]{40}$' \
    && { test -z "$VCS_REF" || test "$VCS_REF" = "$RELEASE_SHA"; } \
    && ./gradlew :service:installDist --no-daemon -x test -PscoringSourceRevision="$RELEASE_SHA"

FROM --platform=${RELEASE_PLATFORM} ${RUNTIME_IMAGE}
# Both release tools must describe the same exact source; conflicting inputs fail below.
ARG BUILD_IMAGE
ARG RUNTIME_IMAGE
ARG RELEASE_PLATFORM
ARG VCS_REF
ARG RELEASE_SHA=${VCS_REF}
LABEL org.opencontainers.image.revision=$RELEASE_SHA \
      io.frwhoop.algorithm.roles="frwhoop-physiology-2,frwhoop-server-2-history" \
      io.frwhoop.heartbeat.contract="physiology_worker_heartbeats-v1" \
      io.frwhoop.database.ca.sha256="700723581420dd1ac98fd7e9ac529f0ef210eadcaf87fc868a3ad7d114c2f3b7" \
      io.frwhoop.build.image=$BUILD_IMAGE \
      io.frwhoop.runtime.image=$RUNTIME_IMAGE \
      io.frwhoop.image.platform=$RELEASE_PLATFORM
WORKDIR /app
COPY --from=build /build/scoring-service/service/build/install/service /app/
COPY Tools/release/certificates/supabase-prod-ca-2021.crt /opt/frwhoop/supabase-prod-ca-2021.crt
RUN printf '%s\n' '700723581420dd1ac98fd7e9ac529f0ef210eadcaf87fc868a3ad7d114c2f3b7  /opt/frwhoop/supabase-prod-ca-2021.crt' | sha256sum -c - \
    && chmod 444 /opt/frwhoop/supabase-prod-ca-2021.crt
RUN test "${#RELEASE_SHA}" -eq 40 && printf '%s\n' "$RELEASE_SHA" | grep -Eq '^[0-9a-f]{40}$' \
    && { test -z "$VCS_REF" || test "$VCS_REF" = "$RELEASE_SHA"; } \
    && printf '%s\n' "$RELEASE_SHA" > /app/release.sha && chmod 444 /app/release.sha
ENV JAVA_OPTS="-Xmx1g -XX:+UseContainerSupport"
ENTRYPOINT ["/app/bin/service"]
