# Multi-stage build: analytics-kernel oracle + scoring service JRE 17 image.
ARG BUILD_IMAGE=eclipse-temurin:17-jdk-jammy
ARG RUNTIME_IMAGE=eclipse-temurin:17-jre-jammy
FROM ${BUILD_IMAGE} AS build
WORKDIR /build
# Analytics kernel sources live in ../android — build context must be the repo root:
#   docker build -f scoring-service/Dockerfile .
COPY android /build/android
COPY scoring-service /build/scoring-service
WORKDIR /build/scoring-service
RUN chmod +x gradlew
RUN ./gradlew :service:installDist --no-daemon -x test

FROM ${RUNTIME_IMAGE}
ARG VCS_REF
LABEL org.opencontainers.image.revision="${VCS_REF}"
WORKDIR /app
COPY --from=build /build/scoring-service/service/build/install/service /app/
ENV JAVA_OPTS="-Xmx1g -XX:+UseContainerSupport"
ENTRYPOINT ["/app/bin/service"]
