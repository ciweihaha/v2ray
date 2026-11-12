##
# Base image pinned by version and manifest digest (Docker Hub, alpine:3.24.4, pushed 2026-11-08).
# Non-root evaluation: xf.sh installs to /usr/bin, /usr/local/share/v2ray and /etc/v2ray and runs v2ray from those system paths, so a non-root user would require changing the default install paths (V2RAY_* overrides) and runtime permissions. Root is therefore retained as a design choice, not changed here.
FROM alpine:3.24.4@sha256:f59abe656b692d901e184be3445e084786602108599d2a51d229c0f5a48c71bf

# The v2ray release installed at build time. Keep in sync with the
# default V2RAY_VERSION in xf.sh (and its pinned SHA512 values).
ARG V2RAY_VERSION=v5.56.0

WORKDIR /root
COPY xf.sh entrypoint.sh /root/

# openssl and ca-certificates are pinned to the Alpine v3.24 versions current at 2026-11-07 (unchanged since 2026-10-25); tzdata remains floating (frequently updated timezone data).
# NOTE: Alpine keeps only the latest package version per branch, so a
# pinned exact version disappears from the repository once superseded
# and a future build fails until the pin is bumped by hand. Dependabot
# does not update apk pins inside RUN, so treat a build failure on a
# missing apk version as the reminder to bump these pins.
RUN set -ex \
    && apk add --no-cache tzdata "openssl=3.5.9-r0" "ca-certificates=20261020-r0" \
    && mkdir -p /etc/v2ray /usr/local/share/v2ray \
    && chmod +x /root/xf.sh /root/entrypoint.sh \
    && VMESS_UUID=11111111-2222-3333-4444-555555555555 V2RAY_SKIP_RUN=1 V2RAY_VERSION="${V2RAY_VERSION}" sh /root/xf.sh
# v2ray is installed at build time (not on every container start), so
# starting a container needs no network and no re-download. The
# build-time install writes a placeholder config with the test UUID
# above; entrypoint.sh overwrites it at container start with the real
# VMESS_UUID, so the placeholder never serves traffic. Bare-metal
# installs keep using xf.sh directly.

EXPOSE 8080
# Process liveness probe: a plain HTTP GET to the VMess/WebSocket
# inbound is not a valid probe (v2ray answers non-WebSocket requests
# with an error), so the healthcheck checks for the process instead.
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
    CMD pidof v2ray >/dev/null || exit 1

CMD ["/root/entrypoint.sh"]
