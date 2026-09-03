FROM ghcr.io/parkervcp/yolks:ubuntu

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
    apt-get install -y \
        docker.io \
        docker-compose-v2 \
        curl \
        jq \
        iproute2 \
        ca-certificates && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*