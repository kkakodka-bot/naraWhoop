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
ARG RELEASE_SHA=unknown
LABEL org.opencontainers.image.revision=$RELEASE_SHA
WORKDIR /app
COPY --from=build /build/scoring-service/service/build/install/service /app/
ENV JAVA_OPTS="-Xmx1g -XX:+UseContainerSupport"
ENTRYPOINT ["/app/bin/service"]
