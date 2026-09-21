# Multi-stage build: analytics-kernel oracle + scoring service JRE 17 image.
ARG BUILD_IMAGE=eclipse-temurin:17-jdk-jammy
ARG RUNTIME_IMAGE=eclipse-temurin:17-jre-jammy
FROM ${BUILD_IMAGE} AS build
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

FROM ${RUNTIME_IMAGE}
# Both release tools must describe the same exact source; conflicting inputs fail below.
ARG VCS_REF
ARG RELEASE_SHA=${VCS_REF}
LABEL org.opencontainers.image.revision=$RELEASE_SHA
WORKDIR /app
COPY --from=build /build/scoring-service/service/build/install/service /app/
RUN test "${#RELEASE_SHA}" -eq 40 && printf '%s\n' "$RELEASE_SHA" | grep -Eq '^[0-9a-f]{40}$' \
    && { test -z "$VCS_REF" || test "$VCS_REF" = "$RELEASE_SHA"; } \
    && printf '%s\n' "$RELEASE_SHA" > /app/release.sha && chmod 444 /app/release.sha
ENV JAVA_OPTS="-Xmx1g -XX:+UseContainerSupport"
ENTRYPOINT ["/app/bin/service"]
