FROM node:20.18.0-alpine3.20 AS web-builder

ARG WEB_GIT_REPO_URL
ARG WEB_GIT_BRANCH
# Resolved by the workflow via `git ls-remote` and passed in as the actual commit SHA
# to build. BuildKit caches a RUN layer by its literal instruction text, not by what
# the command would fetch over the network - `git clone $URL` is the same string on
# every run regardless of how many new commits landed upstream, so a remote GHA cache
# was silently reusing a stale clone+build layer run after run. Referencing this ARG
# inside the RUN command below makes the layer's cache key change exactly when the
# resolved commit changes, so a real new commit always busts the cache while an
# unchanged branch still gets a legitimate cache hit.
ARG WEB_GIT_COMMIT=unknown

WORKDIR /
RUN apk add --no-cache git && git clone ${WEB_GIT_REPO_URL} beaver-iot-web

WORKDIR /beaver-iot-web
# Pinned, not floating "latest" - an unpinned pnpm install once broke this build
# outright when pnpm's own upstream shipped a new default (blocking dependency
# install scripts unless explicitly approved) weeks after this last built cleanly,
# with no change on our side. Bump this version deliberately, not by surprise.
RUN echo "Building commit ${WEB_GIT_COMMIT}" && git checkout ${WEB_GIT_BRANCH} && npm install -g pnpm@10.34.5 && pnpm install && pnpm build


FROM alpine:3.20 AS web
COPY --from=web-builder /beaver-iot-web/apps/web/dist /web
RUN apk add --no-cache envsubst nginx nginx-mod-http-headers-more
COPY nginx/envsubst-on-templates.sh /envsubst-on-templates.sh
COPY nginx/main.conf /etc/nginx/nginx.conf
COPY nginx/templates /etc/nginx/templates

ENV BEAVER_IOT_API_HOST=172.17.0.1
ENV BEAVER_IOT_API_PORT=9200
ENV MQTT_BROKER_WS_PATH=/mqtt
ENV MQTT_BROKER_WS_PORT=""
ENV MQTT_BROKER_MOQUETTE_WEBSOCKET_PORT=8083

# Required because this image shares nginx/templates with the monolith, which now has an
# /iriv-stream/ relay block referencing these. Without defaults nginx cannot resolve the
# variables and refuses to start, so omitting them here would break this image outright
# even though nothing in it uses the relay. See beaver-iot-monolith.dockerfile.
ENV EDGEAI_STREAM_HOST=127.0.0.1
ENV EDGEAI_STREAM_API_KEY=""

EXPOSE 80

# Create folder for PID file
RUN mkdir -p /run/nginx

COPY docker-entrypoint.sh /docker-entrypoint.sh
ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["/bin/sh", "-c", "/envsubst-on-templates.sh && nginx -g 'daemon off;'"]
