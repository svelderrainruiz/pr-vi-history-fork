ARG BASE_IMAGE=nationalinstruments/labview:latest-linux
FROM ${BASE_IMAGE}

ARG NODE_VERSION=22.11.0

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl xz-utils \
    && curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz" -o /tmp/node.tar.xz \
    && tar -xJf /tmp/node.tar.xz -C /usr/local --strip-components=1 \
    && rm -f /tmp/node.tar.xz \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

RUN node --version && npm --version
