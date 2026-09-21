ARG NODE=22
FROM node:${NODE}

RUN apt-get update \
    && apt-get install --no-install-recommends -y \
        libyaml-perl \
        zip \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*
