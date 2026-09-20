# Multi-stage build: analytics-kernel oracle + scoring service JRE 17 image.
FROM eclipse-temurin:17-jdk-jammy AS build
WORKDIR /build
# Analytics kernel sources live in ../android — build context must be the repo root:
#   docker build -f scoring-service/Dockerfile .
COPY android /build/android
COPY scoring-service /build/scoring-service
WORKDIR /build/scoring-service
RUN chmod +x gradlew
RUN ./gradlew :service:installDist --no-daemon -x test

FROM eclipse-temurin:17-jre-jammy
ARG RELEASE_SHA
LABEL org.opencontainers.image.revision=$RELEASE_SHA
WORKDIR /app
COPY --from=build /build/scoring-service/service/build/install/service /app/
RUN test "${#RELEASE_SHA}" -eq 40 && printf '%s\n' "$RELEASE_SHA" | grep -Eq '^[0-9a-f]{40}$' \
    && printf '%s\n' "$RELEASE_SHA" > /app/release.sha && chmod 444 /app/release.sha
ENV JAVA_OPTS="-Xmx1g -XX:+UseContainerSupport"
ENTRYPOINT ["/app/bin/service"]
