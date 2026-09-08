# syntax=docker/dockerfile:1.7

# Multi-arch backend image built FROM SOURCE across three repos, with optional
# Hailo NPU binaries baked in only for arm64.
#
# Why three build stages instead of one `mvn install` at the end:
# `application-standard` depends on `beaver-iot-integrations:milesight-gateway` (and
# friends) as ordinary Maven dependencies. If that artifact isn't already sitting in the
# local repo when application-standard builds, Maven resolves it from Maven Central
# instead - silently substituting the published upstream jar for your fork's changes,
# with no error. Core must therefore be installed, then integrations (which itself
# depends on core), then application-standard - all three sharing one local repo. Build
# this yourself without following that order and it will produce a working image that
# quietly ships none of your customizations.
#
# Build (native arch only, for local testing):
#   docker buildx build -f beaver-iot-api-npu.dockerfile \
#     --build-arg API_GIT_REPO_URL=https://github.com/<you>/beaver-iot.git \
#     --build-arg API_GIT_BRANCH=main \
#     --build-arg INTEGRATIONS_GIT_REPO_URL=https://github.com/<you>/beaver-iot-integrations.git \
#     --build-arg INTEGRATIONS_GIT_BRANCH=main \
#     -t beaver-iot-api-npu:test --load .
#
# Build (multi-arch, push):
#   docker buildx build -f beaver-iot-api-npu.dockerfile \
#     --platform linux/amd64,linux/arm64 \
#     --build-arg ... (same as above) \
#     -t ghcr.io/<you>/beaver-iot-api:latest --push .

ARG REVISION=1.3.1

########## Stage 1: beaver-iot core - installs core/services/parent into the shared .m2 ##########
FROM maven:3.9-eclipse-temurin-17 AS core-builder
ARG API_GIT_REPO_URL
ARG API_GIT_BRANCH
ARG REVISION
# Resolved by the workflow via `git ls-remote` to the actual commit SHA to build.
# `git clone --branch X` is the same literal RUN instruction every build regardless of
# how many new commits landed on X, so a remote GHA build cache was reusing a stale
# clone across runs. Referencing this ARG in the clone RUN busts the cache exactly
# when the resolved commit changes, not on every run and not never.
ARG API_GIT_COMMIT=unknown
WORKDIR /src
RUN echo "Building commit ${API_GIT_COMMIT}" && git clone --branch "${API_GIT_BRANCH}" --depth 1 "${API_GIT_REPO_URL}" beaver-iot
WORKDIR /src/beaver-iot
# This intentionally fails at the `application` module, which needs the integrations
# jars built in the next stage. Every module before that succeeds and is installed.
RUN mvn install -Dmaven.test.skip=true -Drevision="${REVISION}" -B \
    -Dmaven.repo.local=/root/.m2/repository || true

########## Stage 2: beaver-iot-integrations, built against that same .m2 ##########
FROM maven:3.9-eclipse-temurin-17 AS integrations-builder
ARG INTEGRATIONS_GIT_REPO_URL
ARG INTEGRATIONS_GIT_BRANCH
ARG REVISION
ARG INTEGRATIONS_GIT_COMMIT=unknown
COPY --from=core-builder /root/.m2 /root/.m2
WORKDIR /src
RUN echo "Building commit ${INTEGRATIONS_GIT_COMMIT}" && git clone --branch "${INTEGRATIONS_GIT_BRANCH}" --depth 1 "${INTEGRATIONS_GIT_REPO_URL}" beaver-iot-integrations
WORKDIR /src/beaver-iot-integrations
RUN mvn install -Dmaven.test.skip=true -Drevision="${REVISION}" -B \
    -Dmaven.repo.local=/root/.m2/repository

########## Stage 3: application-standard fat jar - both prerequisites are now in .m2 ##########
FROM maven:3.9-eclipse-temurin-17 AS app-builder
ARG API_GIT_REPO_URL
ARG API_GIT_BRANCH
ARG REVISION
ARG API_GIT_COMMIT=unknown
COPY --from=integrations-builder /root/.m2 /root/.m2
WORKDIR /src
RUN echo "Building commit ${API_GIT_COMMIT}" && git clone --branch "${API_GIT_BRANCH}" --depth 1 "${API_GIT_REPO_URL}" beaver-iot
WORKDIR /src/beaver-iot
RUN mvn install -Dmaven.test.skip=true -Drevision="${REVISION}" -B \
    -Dmaven.repo.local=/root/.m2/repository \
    -pl application/application-standard -am

########## Stage 4: Hailo NPU binaries - populated only when building for arm64 ##########
# `scratch` has no shell, so these stages can only ever contain exactly the files
# COPYed into them - there's no way for arm64-only content to leak into the amd64 stage.
FROM scratch AS hailo-arm64
COPY hailo-context/hailo-ollama /hailo-ollama
COPY hailo-context/hailo-ollama-share /hailo-ollama-share
COPY hailo-context/libhailort.so.5.3.0 /libhailort.so.5.3.0

FROM scratch AS hailo-amd64
# Deliberately empty: no Hailo hardware exists for this architecture.

# TARGETARCH is populated automatically by buildx per platform in the build matrix.
ARG TARGETARCH
FROM hailo-${TARGETARCH} AS hailo-binaries

########## Stage 5: runtime ##########
FROM debian:trixie-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
    openjdk-21-jre-headless \
    libssl3 \
    libusb-1.0-0 \
    libudev1 \
    zlib1g \
    libzstd1 \
    libcap2 \
    fontconfig \
    fonts-dejavu-core \
    fonts-noto-core \
    fonts-noto-cjk \
    fonts-noto-color-emoji \
    && rm -rf /var/lib/apt/lists/*

# Install the Hailo binaries only if this build actually produced any (arm64). On
# amd64 the source stage is empty, so this is a silent, harmless no-op - the app's
# LocalOllamaProcessManager already checks for the binary's presence at startup and
# skips NPU/local-Ollama features gracefully when it's absent.
COPY --from=hailo-binaries / /opt/hailo-src/
RUN if [ -f /opt/hailo-src/hailo-ollama ]; then \
        cp /opt/hailo-src/hailo-ollama /usr/bin/hailo-ollama && \
        chmod +x /usr/bin/hailo-ollama && \
        cp -r /opt/hailo-src/hailo-ollama-share /usr/share/hailo-ollama && \
        cp /opt/hailo-src/libhailort.so.5.3.0 /usr/lib/libhailort.so.5.3.0 && \
        ln -s /usr/lib/libhailort.so.5.3.0 /usr/lib/libhailort.so && \
        ldconfig && \
        echo "Hailo NPU binaries installed (arm64 build)"; \
    else \
        echo "No Hailo binaries for this platform - NPU/local-Ollama features will be unavailable at runtime"; \
    fi; \
    rm -rf /opt/hailo-src

COPY --from=app-builder /src/beaver-iot/application/application-standard/target/application-standard-exec.jar /application.jar

# JAVA_OPTS / SPRING_OPTS and -Dloader.path match upstream's own beaver-iot-api image -
# ${HOME}/beaver-iot/integrations (i.e. /root/beaver-iot/integrations, since this image
# runs as root and HOME defaults to /root) is a Spring Boot PropertiesLauncher extra
# classpath dir, letting a user drop additional integration jars into a mounted volume
# at runtime without rebuilding the image. This is on top of, not instead of, the
# milesight-gateway integration already compiled into the jar above via the 3-stage
# Maven build - that one doesn't need this mechanism, but a user's own custom
# integration would.
ENV JAVA_OPTS=""
ENV SPRING_OPTS=""

# /root/beaver-iot is NOT declared as a VOLUME here, deliberately - it was, and that
# caused real data loss: a declared VOLUME with no matching explicit mount at container
# recreation time makes Docker silently create a fresh, empty anonymous volume there,
# shadowing whatever was already at that path (the app's actual H2 database, among
# other things) even under an otherwise-correct outer bind mount at /root. Deployments
# must mount this path explicitly instead (see DEPLOYMENT.md) - a plain directory
# under an already-mounted parent needs no separate VOLUME declaration to persist.
VOLUME /tmp

EXPOSE 9200 9201 1883 8083 11434

COPY docker-entrypoint.sh /docker-entrypoint.sh
ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["/bin/sh", "-c", "java -Dloader.path=${HOME}/beaver-iot/integrations ${JAVA_OPTS} -jar /application.jar ${SPRING_OPTS}"]
