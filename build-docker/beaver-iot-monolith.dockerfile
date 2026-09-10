# Single-container "monolith" image, for parity with Milesight's own official
# `milesight/beaver-iot` UX (a plain `docker run`, no compose needed). Combines our
# already-built beaver-iot-api and beaver-iot-web images into one container: nginx
# fronts the web UI and proxies to the API, which runs in the same container as a
# second, foregrounded process.
#
# Adapted from Milesight's own build-docker/beaver-iot.dockerfile, which assumes an
# Alpine base (apk) - ours is Debian (debian:trixie-slim, chosen for the Hailo NPU
# dependencies in beaver-iot-api-npu.dockerfile), so the nginx + headers-more-filter
# module install below uses apt instead. Verified locally that Debian's
# libnginx-mod-http-headers-more-filter package installs the module at the exact same
# path (/usr/lib/nginx/modules/ngx_http_headers_more_filter_module.so) that
# nginx/main.conf already expects, so main.conf and the templates are reused unchanged.
#
# Build:
#   docker buildx build -f beaver-iot-monolith.dockerfile \
#     --build-arg BASE_API_IMAGE=ghcr.io/<you>/beaver-iot-api:latest \
#     --build-arg BASE_WEB_IMAGE=ghcr.io/<you>/beaver-iot-web:latest \
#     --platform linux/amd64,linux/arm64 \
#     -t ghcr.io/<you>/beaver-iot:latest --push .

ARG BASE_API_IMAGE
ARG BASE_WEB_IMAGE

FROM ${BASE_WEB_IMAGE} AS web

FROM ${BASE_API_IMAGE} AS monolith
COPY --from=web /web /web

RUN apt-get update && apt-get install -y --no-install-recommends \
    nginx \
    libnginx-mod-http-headers-more-filter \
    gettext-base \
    && rm -rf /var/lib/apt/lists/*

COPY nginx/envsubst-on-templates.sh /envsubst-on-templates.sh
COPY nginx/main.conf /etc/nginx/nginx.conf
COPY nginx/templates /etc/nginx/templates

ENV BEAVER_IOT_API_HOST=localhost
ENV BEAVER_IOT_API_PORT=9200
ENV MQTT_BROKER_WS_PATH=/mqtt
ENV MQTT_BROKER_WS_PORT=""
ENV MQTT_BROKER_MOQUETTE_WEBSOCKET_PORT=8083

EXPOSE 80 9200 9201 1883 8083 11434

# ENTRYPOINT (docker-entrypoint.sh) and the JAVA_OPTS/SPRING_OPTS/-Dloader.path CMD
# pattern already come from the beaver-iot-api base image. This CMD only adds nginx in
# front of it, deliberately backgrounded (no `-g 'daemon off;'`, unlike the standalone
# web image) so the shell chain falls through to java as the container's foreground
# process - same single-container, two-process pattern as Milesight's own monolith.
CMD ["/bin/sh", "-c", "/envsubst-on-templates.sh && nginx && java -Dloader.path=${HOME}/beaver-iot/integrations ${JAVA_OPTS} -jar /application.jar ${SPRING_OPTS}"]
