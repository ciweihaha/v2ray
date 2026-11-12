#!/bin/sh
##
# Container runtime entrypoint. The v2ray binary is installed at image
# build time (see Dockerfile); this script only validates VMESS_UUID,
# writes the runtime config and execs v2ray. It never downloads
# anything, so a container starts without network access and restarts
# fast. Bare-metal installs keep using xf.sh directly.
#
# NOTE: the UUID validation and the config document below intentionally
# mirror xf.sh; keep the two in sync when either changes.

# The VMess client UUID must come from the environment. Fail closed when unset:
if [ -z "${VMESS_UUID:-}" ]; then
    echo "Error: VMESS_UUID is not set; refusing to start v2ray without an explicit UUID" >&2
    exit 1
fi

# Same 8-4-4-4-12 hexadecimal validation as xf.sh: only hex digits and
# hyphens can reach the generated JSON, so no JSON escaping is needed.
case "${VMESS_UUID}" in
    ????????-????-????-????-????????????) ;;
    *)
        echo "Error: VMESS_UUID must be a UUID in 8-4-4-4-12 hexadecimal form" >&2
        exit 1
        ;;
esac
UUID_HEX=$(printf '%s' "${VMESS_UUID}" | tr -d '-')
case "${UUID_HEX}" in
    *[!0-9a-fA-F]*)
        echo "Error: VMESS_UUID must be a UUID in 8-4-4-4-12 hexadecimal form" >&2
        exit 1
        ;;
esac

BIN_DIR="${V2RAY_BIN_DIR:-/usr/bin}"
CONFIG_FILE="${V2RAY_CONFIG_FILE:-/etc/v2ray/config.json}"

[ -x "${BIN_DIR}/v2ray" ] || {
    echo "Error: v2ray binary not found at ${BIN_DIR}/v2ray (the image installs it at build time)" >&2
    exit 1
}

CONFIG_DIR=$(dirname "${CONFIG_FILE}")
mkdir -p "${CONFIG_DIR}" || {
    echo "Error: failed to prepare config directory ${CONFIG_DIR}" >&2
    exit 1
}
# The config holds the VMess UUID, the service's only credential.
if [ "${CONFIG_DIR}" != "/" ]; then
    chmod 700 "${CONFIG_DIR}" || {
        echo "Error: failed to restrict ${CONFIG_DIR} to 0700" >&2
        exit 1
    }
fi

# Atomic write, as in xf.sh: write a temp file in the same directory,
# restrict it to 0600 BEFORE the rename (so the UUID is never
# world-readable, even briefly), flush, then rename over the target.
# This overwrites the placeholder config written at image build time.
CONFIG_TMP="${CONFIG_FILE}.tmp.$$"
trap 'rm -f "${CONFIG_TMP}"' EXIT HUP INT TERM
if ! cat >"${CONFIG_TMP}" <<EOF
{
    "log": {
        "loglevel": "warning"
    },
    "inbounds": [
        {
            "listen": "0.0.0.0",
            "port": 8080,
            "protocol": "vmess",
            "settings": {
                "clients": [
                    {
                        "id": "${VMESS_UUID}",
                        "alterId": 0
                    }
                ],
                "disableInsecureEncryption": true
            },
            "streamSettings": {
                "network": "ws"
            }
        }
    ],
    "outbounds": [
        {
            "protocol": "freedom"
        }
    ]
}
EOF
then
    echo "Error: failed to write ${CONFIG_TMP}" >&2
    exit 1
fi
chmod 600 "${CONFIG_TMP}" || {
    echo "Error: failed to restrict ${CONFIG_TMP} to 0600" >&2
    exit 1
}
sync || {
    echo "Error: failed to sync ${CONFIG_TMP}" >&2
    exit 1
}
mv -f "${CONFIG_TMP}" "${CONFIG_FILE}" || {
    echo "Error: failed to install ${CONFIG_FILE}" >&2
    exit 1
}
trap - EXIT HUP INT TERM

echo "--------------------------------"
echo "V2Ray UUID: <from VMESS_UUID env; not printed>"
echo "--------------------------------"

# exec replaces this shell: entrypoint.sh runs as PID 1 in the
# container, and a PID 1 shell does not forward signals to its
# children. After exec, v2ray itself is PID 1 and receives signals
# directly; the exit code is v2ray's either way.
# v2ray 5.x is subcommand-based: bare `-config` is rejected with
# "flag provided but not defined: -config" (exit 2); `run` is the
# subcommand that starts the server with a config file.
exec "${BIN_DIR}/v2ray" run -config "${CONFIG_FILE}"
