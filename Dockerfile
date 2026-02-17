FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    curl \
    coreutils \
    iproute2 \
    procps \
    findutils \
    grep \
    gawk \
    nginx \
    cron \
    sudo \
    openssh-client \
    && rm -rf /var/lib/apt/lists/*

# Copy LaraWatch into the container
COPY . /opt/larawatch
RUN chmod +x /opt/larawatch/larawatch /opt/larawatch/test/setup.sh

# Set up test fixtures
RUN /opt/larawatch/test/setup.sh

WORKDIR /opt/larawatch

ENTRYPOINT ["/bin/bash"]
