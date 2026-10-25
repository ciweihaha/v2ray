#!/bin/sh
##

# Set ARG
# The VMess client UUID must come from the environment. Fail closed when unset:
if [ -z "${VMESS_UUID:-}" ]; then
    echo "Error: VMESS_UUID is not set; refusing to write a v2ray config without an explicit UUID" >&2
    exit 1
fi

# The UUID must be the standard 8-4-4-4-12 hexadecimal form. This also
# makes the heredoc interpolation below safe: only hex digits and hyphens
# can reach the generated JSON, so no JSON escaping is needed. A
# non-standard form (for example, without hyphens) is rejected; if such a
# form is ever needed, it must be documented and explicitly allowed here.
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

ARCH="64"

# Install locations. The V2RAY_* overrides exist so the installer can be
# exercised in isolation (drills, CI) without touching a live system;
# defaults preserve the historical install locations.
BIN_DIR="${V2RAY_BIN_DIR:-/usr/bin}"
SHARE_DIR="${V2RAY_SHARE_DIR:-/usr/local/share/v2ray}"
CONFIG_FILE="${V2RAY_CONFIG_FILE:-/etc/v2ray/config.json}"

# Always work in a fresh temporary directory. A stale /tmp/v2ray left by a
# previous run must never be reused: if a download fails, an old zip sitting
# in a reused directory could otherwise pass the checksum and silently mask
# the failed download.
DOWNLOAD_PATH="$(mktemp -d /tmp/v2ray.XXXXXX)" || {
    echo "Error: failed to create a temporary download directory" >&2
    exit 1
}
# Backup directory for files this run may replace; used only for rollback.
BACKUP_DIR="$(mktemp -d /tmp/v2ray-backup.XXXXXX)" || {
    echo "Error: failed to create a temporary backup directory" >&2
    rm -rf "${DOWNLOAD_PATH}"
    exit 1
}

# Set to 1 once backups are taken, i.e. once the install phase has started.
# Failures before that point have changed nothing, so rollback must not run.
INSTALL_STARTED=0

# Rollback: restore every previously existing target from backup; remove any
# target this run created where nothing existed before. Best effort only:
# failures here must not mask the original error (the trap never calls exit).
rollback() {
    [ "${INSTALL_STARTED}" = "1" ] || return 0
    for spec in "v2ray:${BIN_DIR}/v2ray" "v2ctl:${BIN_DIR}/v2ctl" "geosite.dat:${SHARE_DIR}/geosite.dat" "geoip.dat:${SHARE_DIR}/geoip.dat" "config.json:${CONFIG_FILE}"; do
        name="${spec%%:*}"
        target="${spec#*:}"
        if [ -f "${BACKUP_DIR}/${name}" ]; then
            mv -f "${BACKUP_DIR}/${name}" "${target}"
        else
            rm -f "${target}"
        fi
    done
}

cleanup() {
    # The atomic config temporary file (if one was created) is part of the
    # rollback/cleanup inventory: remove any leftover copy on every exit path.
    if [ -n "${CONFIG_TMP:-}" ]; then
        rm -f "${CONFIG_TMP}"
    fi
    rm -rf "${DOWNLOAD_PATH}" "${BACKUP_DIR}"
}

# On any non-zero exit, roll back before the temp dirs are removed.
on_exit() {
    status=$?
    if [ "${status}" -ne 0 ]; then
        rollback
    fi
    cleanup
}
trap on_exit EXIT

fail() {
    echo "Error: $*" >&2
    exit 1
}

cd "${DOWNLOAD_PATH}" || fail "cannot enter download directory ${DOWNLOAD_PATH}"

# Pin the upstream release instead of following the moving "latest" alias on every run.
# Override with V2RAY_VERSION=<tag> when a different pinned release is needed.
V2RAY_VERSION="${V2RAY_VERSION:-v5.53.0}"
case "${V2RAY_VERSION}" in
    v[0-9]*.*) ;;
    *) echo "Error: V2RAY_VERSION must be a release tag like v5.53.0 (got: ${V2RAY_VERSION})" >&2 && exit 1 ;;
esac
TAG="${V2RAY_VERSION}"
echo "The v2ray version: ${TAG}"

# Download files
V2RAY_FILE="v2ray-linux-${ARCH}.zip"
DGST_FILE="v2ray-linux-${ARCH}.zip.dgst"
DOWNLOAD_BASE="${V2RAY_DOWNLOAD_BASE:-https://github.com/v2fly/v2ray-core/releases/download/${TAG}}"
if [ -n "${V2RAY_DOWNLOAD_BASE:-}" ]; then
    echo "Warning: V2RAY_DOWNLOAD_BASE is overridden; downloads will come from ${DOWNLOAD_BASE}" >&2
fi
echo "Downloading binary file: ${V2RAY_FILE}"
echo "Downloading binary file: ${DGST_FILE}"

# Each download is checked immediately. The old code ran both wgets and then
# tested $? once, so a failed first download was masked whenever the second
# one succeeded. Output goes to a log that is shown only on failure, so a
# failed download is visible instead of being discarded to /dev/null.
if ! wget -O "${DOWNLOAD_PATH}/v2ray.zip" "${DOWNLOAD_BASE}/${V2RAY_FILE}" >"${DOWNLOAD_PATH}/wget-v2ray.log" 2>&1; then
    echo "Error: Failed to download ${V2RAY_FILE} from ${DOWNLOAD_BASE}" >&2
    cat "${DOWNLOAD_PATH}/wget-v2ray.log" >&2
    exit 1
fi
if ! wget -O "${DOWNLOAD_PATH}/v2ray.zip.dgst" "${DOWNLOAD_BASE}/${DGST_FILE}" >"${DOWNLOAD_PATH}/wget-dgst.log" 2>&1; then
    echo "Error: Failed to download ${DGST_FILE} from ${DOWNLOAD_BASE}" >&2
    cat "${DOWNLOAD_PATH}/wget-dgst.log" >&2
    exit 1
fi
echo "Download binary file: ${V2RAY_FILE} ${DGST_FILE} completed"

# Check SHA512
# Compare hex digests only: openssl prints "SHA2-512(v2ray.zip)= <hex>" while the
# .dgst file has lines like "SHA512 (v2ray-linux-64.zip) = <hex>"; comparing full
# strings never matched, so the check always failed.
LOCAL=$(openssl dgst -sha512 v2ray.zip | awk '{print $NF}')
STR=$(grep -i '^SHA512' v2ray.zip.dgst | head -n1 | awk '{print $NF}')

if [ -z "${LOCAL}" ] || [ -z "${STR}" ]; then
    echo " Check failed: could not read SHA512 values" && exit 1
fi

if [ "${LOCAL}" = "${STR}" ]; then
    echo " Check passed" && rm -fv v2ray.zip.dgst
else
    echo " Check have not passed yet " && exit 1
fi

# Prepare
echo "Prepare to use"
# Defence in depth before unpacking: refuse any entry that would escape the
# download directory (an absolute path, or a parent-directory component).
# The .dgst check above only guards against transport corruption: the
# .dgst file comes from the same release as the zip, so it cannot prove
# the release itself was not tampered with.
if ! unzip -Z1 v2ray.zip >"${DOWNLOAD_PATH}/zip-entries.txt"; then
    fail "failed to list v2ray.zip"
fi
if grep -Eq '(^|/)\.\.(/|$)|^/' "${DOWNLOAD_PATH}/zip-entries.txt"; then
    echo "Error: v2ray.zip contains an entry with an absolute path or a parent-directory component; refusing to unpack" >&2
    exit 1
fi
unzip -o v2ray.zip || fail "failed to unpack v2ray.zip"

# Refuse to install an incomplete file set: nothing under the install
# locations may change until every expected file is present.
for f in v2ray v2ctl geosite.dat geoip.dat; do
    [ -f "${f}" ] || fail "downloaded archive is missing ${f}; refusing to install an incomplete file set"
done
chmod +x v2ray v2ctl || fail "failed to make v2ray binaries executable"

mkdir -p "${BIN_DIR}" "${SHARE_DIR}" || fail "failed to prepare install directories"
CONFIG_DIR=$(dirname "${CONFIG_FILE}")
mkdir -p "${CONFIG_DIR}" || fail "failed to prepare config directory ${CONFIG_DIR}"

# Back up everything this run may replace, before replacing anything.
for spec in "v2ray:${BIN_DIR}/v2ray" "v2ctl:${BIN_DIR}/v2ctl" "geosite.dat:${SHARE_DIR}/geosite.dat" "geoip.dat:${SHARE_DIR}/geoip.dat" "config.json:${CONFIG_FILE}"; do
    name="${spec%%:*}"
    target="${spec#*:}"
    if [ -f "${target}" ]; then
        cp -f "${target}" "${BACKUP_DIR}/${name}" || fail "failed to back up ${target}"
    fi
done
INSTALL_STARTED=1

mv -f v2ray v2ctl "${BIN_DIR}/" || fail "failed to install v2ray binaries to ${BIN_DIR}"
mv -f geosite.dat geoip.dat "${SHARE_DIR}/" || fail "failed to install v2ray data files to ${SHARE_DIR}"
# mv config.json /etc/v2ray/config.json

# Set config file
# Write to a temporary file in the same directory, flush it, then rename it
# over the target. A normal failure still goes through the trap rollback
# above; this only closes the hard-interruption window in which the trap
# does not run and a direct write could leave a truncated config. The
# temporary name carries $$ to avoid collisions between concurrent runs,
# and cleanup() removes any leftover temporary file (it is part of the
# rollback/cleanup inventory, alongside the backed-up config).
CONFIG_TMP="${CONFIG_FILE}.tmp.$$"
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
    rm -f "${CONFIG_TMP}"
    fail "failed to write ${CONFIG_TMP}"
fi
sync || fail "failed to sync ${CONFIG_TMP}"
mv -f "${CONFIG_TMP}" "${CONFIG_FILE}" || {
    rm -f "${CONFIG_TMP}"
    fail "failed to install ${CONFIG_FILE}"
}

echo "Install done"

echo "--------------------------------"
echo "Fly App Name: ${FLY_APP_NAME:-}"
echo "Fly App Region: ${FLY_REGION:-}"
echo "V2Ray UUID: <from VMESS_UUID env; not printed>"
echo "--------------------------------"

# Install succeeded: the trap must not roll anything back afterwards, and the
# temp dirs are no longer needed. A later v2ray runtime failure must not
# uninstall what was just installed.
trap - EXIT
cleanup

# Run v2ray (skipped by drills via V2RAY_SKIP_RUN=1)
if [ "${V2RAY_SKIP_RUN:-}" != "1" ]; then
    "${BIN_DIR}/v2ray" -config "${CONFIG_FILE}"
fi
