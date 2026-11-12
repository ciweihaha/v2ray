##
# Base image pinned by version and manifest digest (Docker Hub, alpine:3.24.4, pushed 2026-11-08).
# Non-root evaluation: xf.sh installs to /usr/bin, /usr/local/share/v2ray and /etc/v2ray and runs v2ray from those system paths, so a non-root user would require changing the default install paths (V2RAY_* overrides) and runtime permissions. Root is therefore retained as a design choice, not changed here.
FROM alpine:3.24.4@sha256:f59abe656b692d901e184be3445e084786602108599d2a51d229c0f5a48c71bf

WORKDIR /root
COPY xf.sh /root/xf.sh

# openssl and ca-certificates are pinned to the Alpine v3.24 versions current at 2026-11-07 (unchanged since 2026-10-25); tzdata remains floating (frequently updated timezone data).
RUN set -ex \
    && apk add --no-cache tzdata "openssl=3.5.9-r0" "ca-certificates=20261020-r0" \
    && mkdir -p /etc/v2ray /usr/local/share/v2ray /var/log/v2ray \
    && chmod +x /root/xf.sh

CMD ["/root/xf.sh"]
