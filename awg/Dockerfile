FROM golang:1.24 AS builder

RUN apt-get update && apt-get install -y \
    git \
    make \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

RUN git clone https://github.com/amnezia-vpn/amneziawg-go.git

WORKDIR /build/amneziawg-go

RUN make

FROM ubuntu:22.04

RUN apt-get update && apt-get install -y --no-install-recommends \
    software-properties-common gnupg2 \
    iproute2 iptables curl net-tools iputils-ping \
    python3-minimal ipset cron \
    && add-apt-repository ppa:amnezia/ppa \
    && apt-get update \
    && apt-get install -y --no-install-recommends amneziawg-tools \
    && rm -rf /var/lib/apt/lists/* \
    && apt-get purge -y software-properties-common gnupg2 \
    && apt-get autoremove -y

WORKDIR /etc/amnezia

COPY --from=builder /build/amneziawg-go/amneziawg-go /usr/local/bin/amneziawg-go
RUN chmod +x /usr/local/bin/amneziawg-go

COPY process_config.py /usr/local/bin/process_config.py
RUN chmod +x /usr/local/bin/process_config.py

COPY update_blocklist.sh /usr/local/bin/update_blocklist.sh
RUN chmod +x /usr/local/bin/update_blocklist.sh

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

RUN mkdir -p /etc/amnezia/run

ENTRYPOINT ["/entrypoint.sh"]