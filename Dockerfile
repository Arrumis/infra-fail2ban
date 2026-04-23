FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    fail2ban \
    iptables \
    iproute2 \
    iptables-persistent \
    docker.io \
    curl \
    ca-certificates \
    tzdata \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

ENV TZ=Asia/Tokyo

RUN rm -f /etc/fail2ban/jail.d/sshd.conf
RUN rm -f /etc/fail2ban/jail.d/defaults-debian.conf

RUN mkdir -p /etc/fail2ban

VOLUME ["/data"]

CMD ["fail2ban-server", "-f", "-x"]
