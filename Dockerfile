##
# Base image pinned by version and manifest digest (Docker Hub, alpine:3.24.3, pushed 2026-10-23).
# Non-root evaluation: xf.sh installs to /usr/bin, /usr/local/share/v2ray and /etc/v2ray and runs v2ray from those system paths, so a non-root user would require changing the default install paths (V2RAY_* overrides) and runtime permissions. Root is therefore retained as a design choice, not changed here.
FROM alpine:3.24.3@sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a

WORKDIR /root
COPY xf.sh /root/xf.sh

# openssl and ca-certificates are pinned to the Alpine v3.24 versions current at 2026-10-25; tzdata remains floating (frequently updated timezone data).
RUN set -ex \
    && apk add --no-cache tzdata "openssl=3.5.9-r0" "ca-certificates=20261020-r0" \
    && mkdir -p /etc/v2ray /usr/local/share/v2ray /var/log/v2ray \
    && chmod +x /root/xf.sh

CMD ["/root/xf.sh"]
