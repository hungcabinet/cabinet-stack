FROM ubuntu:22.04

RUN apt-get update && apt-get install -y --no-install-recommends \
    iproute2 \
    iptables \
    wget \
    tar \
    curl \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

ARG SING_BOX_VERSION=1.13.9

RUN wget -O sing-box.tar.gz \
    https://github.com/SagerNet/sing-box/releases/download/v${SING_BOX_VERSION}/sing-box-${SING_BOX_VERSION}-linux-amd64.tar.gz \
    && tar -xzf sing-box.tar.gz \
    && cp sing-box-${SING_BOX_VERSION}-linux-amd64/sing-box /usr/local/bin/sing-box \
    && chmod +x /usr/local/bin/sing-box \
    && rm -rf sing-box.tar.gz sing-box-${SING_BOX_VERSION}-linux-amd64

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]