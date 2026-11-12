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

# CPU architecture: upstream ships one zip per CPU (v2ray-linux-64.zip for
# x86_64, v2ray-linux-arm64-v8a.zip for aarch64, ...). Detect it from
# uname -m instead of assuming 64-bit x86: on an ARM host the old code
# downloaded the x86_64 zip and the binary then failed to execute.
# V2RAY_ARCH overrides the detection; it accepts either a uname -m value
# or an upstream suffix directly. Anything else fails closed with a
# clear error instead of downloading a wrong-arch zip.
ARCH="${V2RAY_ARCH:-$(uname -m)}"
case "${ARCH}" in
    x86_64|amd64) ARCH="64" ;;
    i386|i686) ARCH="32" ;;
    aarch64|arm64) ARCH="arm64-v8a" ;;
    armv7l) ARCH="arm32-v7a" ;;
    armv6l) ARCH="arm32-v6" ;;
    armv5tel|armv5tejl) ARCH="arm32-v5" ;;
    loongarch64) ARCH="loong64" ;;
    riscv64) ARCH="riscv64" ;;
    32|64|arm32-v5|arm32-v6|arm32-v7a|arm64-v8a|loong64|mips32|mips32le|mips64|mips64le) ;;
    *)
        echo "Error: unsupported CPU architecture '${ARCH}' (uname -m reports '$(uname -m)'); set V2RAY_ARCH to an upstream suffix (64, 32, arm64-v8a, arm32-v7a, riscv64, ...)" >&2
        exit 1
        ;;
esac

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
    for spec in "v2ray:${BIN_DIR}/v2ray" "geosite.dat:${SHARE_DIR}/geosite.dat" "geoip.dat:${SHARE_DIR}/geoip.dat" "config.json:${CONFIG_FILE}"; do
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
# EXITING guards against re-entry: a second signal arriving while a
# rollback is already running must not run rollback twice (the second
# run would find the backups already moved and delete the restored
# files instead of restoring them).
EXITING=0
on_exit() {
    status=$?
    [ "${EXITING}" = "1" ] && return 0
    EXITING=1
    if [ "${status}" -ne 0 ]; then
        rollback
    fi
    cleanup
}
# If the run is interrupted mid-install (Ctrl-C, docker stop, terminal
# hangup), roll back and clean up exactly as on any other failure
# instead of leaving a half-installed v2ray behind: the EXIT trap alone
# does not run when the shell is killed by a signal. The exit status
# follows the 128+signal convention. The trap runs after the current
# foreground command finishes, so a signal during a download is acted
# on once that download ends; nothing has been installed yet at that
# point, so the delayed rollback is still a no-op there.
on_signal() {
    [ "${EXITING}" = "1" ] && return 0
    EXITING=1
    rollback
    cleanup
    exit "$1"
}
trap on_exit EXIT
trap 'on_signal 129' HUP
trap 'on_signal 130' INT
trap 'on_signal 143' TERM

fail() {
    echo "Error: $*" >&2
    exit 1
}

# Fail fast with a clear error if a required helper is missing, instead
# of failing mid-install with a confusing message from a download or
# checksum step -- or, for timeout, running a download with no time
# bound at all. (mktemp is already covered by the explicit checks above;
# the remaining helpers -- awk, grep, tr, dirname, sync, cp, mv -- come
# with the shell's core utilities on every supported host.)
for cmd in wget unzip openssl timeout; do
    command -v "${cmd}" >/dev/null 2>&1 || fail "required command '${cmd}' is not installed"
done

cd "${DOWNLOAD_PATH}" || fail "cannot enter download directory ${DOWNLOAD_PATH}"

# Pin the upstream release instead of following the moving "latest" alias on every run.
# Override with V2RAY_VERSION=<tag> when a different pinned release is needed.
V2RAY_VERSION="${V2RAY_VERSION:-v5.56.0}"
case "${V2RAY_VERSION}" in
    v[0-9]*.*) ;;
    *) echo "Error: V2RAY_VERSION must be a release tag like v5.56.0 (got: ${V2RAY_VERSION})" >&2 && exit 1 ;;
esac
# A version goes into a download URL, so reject anything but letters,
# digits, dots, hyphens and underscores: the shape check above only
# requires a leading v, digits and a dot, so 'v1.2.3; rm -rf /' passed
# validation and only failed later at the download, with a confusing
# error. Quoting already prevents execution, but bad input should be
# rejected here, with this message, not downstream.
case "${V2RAY_VERSION}" in
    *[!0-9A-Za-z._-]*)
        echo "Error: V2RAY_VERSION must be a release tag like v5.56.0 (got: ${V2RAY_VERSION})" >&2
        exit 1
        ;;
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
# Bound every download in time. Without a bound a stalled connection hangs
# the deploy (and CI) until the job timeout: GNU wget retries a timed-out
# download up to 20 times, and BusyBox wget has no read timeout at all by
# default. -T 30 fails a stalled read fast on both (GNU and BusyBox wget
# both accept -T); the timeout wrapper caps the total time per file,
# including GNU wget's retries, on both (timeout is a coreutils utility
# and a BusyBox applet). Override the cap with
# V2RAY_DOWNLOAD_TIMEOUT=<seconds>; drills use a small value.
# Zero is rejected below: GNU timeout treats 0 as "no timeout", so a
# zero cap would silently remove the bound this block promises.
case "${V2RAY_DOWNLOAD_TIMEOUT:-300}" in
    *[!0-9]*)
        echo "Error: V2RAY_DOWNLOAD_TIMEOUT must be a number of seconds" >&2
        exit 1
        ;;
    *[!0]*)
        ;; # contains a non-zero digit: a real bound
    *)
        echo "Error: V2RAY_DOWNLOAD_TIMEOUT must be at least 1 second (0 disables the timeout)" >&2
        exit 1
        ;;
esac
DOWNLOAD_TIMEOUT="${V2RAY_DOWNLOAD_TIMEOUT:-300}"
# An unbounded cap defeats the purpose of the timeout just as surely as
# 0 does (0 is rejected above for exactly that reason), so cap it at one
# hour: a legitimate v2ray zip download never needs longer than that.
if [ "${DOWNLOAD_TIMEOUT}" -gt 3600 ]; then
    echo "Error: V2RAY_DOWNLOAD_TIMEOUT must be at most 3600 seconds (got: ${DOWNLOAD_TIMEOUT})" >&2
    exit 1
fi

echo "Downloading binary file: ${V2RAY_FILE}"
echo "Downloading binary file: ${DGST_FILE}"

# Each download is checked immediately. The old code ran both wgets and then
# tested $? once, so a failed first download was masked whenever the second
# one succeeded. Output goes to a log that is shown only on failure, so a
# failed download is visible instead of being discarded to /dev/null.
# Downloads are retried up to 3 times with exponential backoff (2s, 4s):
# a transient GitHub 5xx or reset connection must not fail a deploy
# outright. Retries never extend the overall bound: every attempt gets
# only the time remaining until the V2RAY_DOWNLOAD_TIMEOUT deadline, so
# the total time for one file stays within the promised cap.
download_with_retry() {
    # $1=url $2=destination $3=log file $4=label for messages
    _url="$1"; _dest="$2"; _log="$3"; _label="$4"
    _deadline=$(( $(date +%s) + DOWNLOAD_TIMEOUT ))
    _attempt=1
    _backoff=2
    while [ "${_attempt}" -le 3 ]; do
        _remaining=$(( _deadline - $(date +%s) ))
        if [ "${_remaining}" -le 0 ]; then
            break
        fi
        if timeout "${_remaining}" wget -T 30 -O "${_dest}" "${_url}" >"${_log}" 2>&1; then
            return 0
        fi
        echo "Warning: download attempt ${_attempt}/3 for ${_label} failed; retrying" >&2
        _attempt=$((_attempt + 1))
        if [ "${_attempt}" -le 3 ]; then
            _remaining=$(( _deadline - $(date +%s) ))
            [ "${_remaining}" -le 0 ] && break
            _sleep="${_backoff}"
            [ "${_sleep}" -gt "${_remaining}" ] && _sleep="${_remaining}"
            sleep "${_sleep}"
            _backoff=$((_backoff * 2))
        fi
    done
    echo "Error: Failed to download ${_label} from ${DOWNLOAD_BASE}" >&2
    cat "${_log}" >&2
    return 1
}
download_with_retry "${DOWNLOAD_BASE}/${V2RAY_FILE}" "${DOWNLOAD_PATH}/v2ray.zip" "${DOWNLOAD_PATH}/wget-v2ray.log" "${V2RAY_FILE}" || exit 1
download_with_retry "${DOWNLOAD_BASE}/${DGST_FILE}" "${DOWNLOAD_PATH}/v2ray.zip.dgst" "${DOWNLOAD_PATH}/wget-dgst.log" "${DGST_FILE}" || exit 1
echo "Download binary file: ${V2RAY_FILE} ${DGST_FILE} completed"

# Check SHA512
# Compare hex digests only (lowercased: the two sources may differ in case).
# openssl prints "SHA2-512(v2ray.zip)= <hex>". The .dgst file lists one
# "KEY= <hex>" line per digest; the SHA-512 line is "SHA2-512= <hex>"
# (older releases used "SHA512 (v2ray-linux-64.zip) = <hex>"). Match the
# key loosely so either form works, and take the first match. The previous
# pattern (^SHA512) matched neither form, so STR was always empty and the
# check always failed. Comparing full strings never matched either.
LOCAL=$(openssl dgst -sha512 v2ray.zip | awk '{print $NF}' | tr '[:upper:]' '[:lower:]')
STR=$(grep -iE '^SHA2?-?512[ (=]' v2ray.zip.dgst | head -n1 | awk '{print $NF}' | tr '[:upper:]' '[:lower:]')

if [ -z "${LOCAL}" ] || [ -z "${STR}" ]; then
    echo " Check failed: could not read SHA512 values" && exit 1
fi

if [ "${LOCAL}" != "${STR}" ]; then
    echo " Check failed: SHA512 mismatch for v2ray.zip" && exit 1
fi

# Independent trust anchor: the .dgst comparison above only guards
# against transport corruption -- the .dgst comes from the same release
# as the zip, so a tampered release (compromised upstream account,
# replaced release, malicious V2RAY_DOWNLOAD_BASE) would pass it. The
# expected SHA512 values below were taken from the upstream v5.56.0
# release's .dgst files and are embedded here, so the downloaded zip is
# also compared against a value that lives in this script, not in the
# release being verified. Update these values whenever the pinned
# version changes (V2RAY_VERSION default above).
# The pinned check applies when downloading the pinned release from the
# default upstream base. It is skipped -- with a warning, falling back
# to the .dgst comparison -- for any other V2RAY_VERSION (no pinned
# value is known for it) or an overridden V2RAY_DOWNLOAD_BASE (an
# explicit operator choice whose content the pinned values cannot
# describe). V2RAY_ENFORCE_PINNED_HASH=1 forces the pinned check even
# with a custom base; drills use it to exercise this path against a
# local fixture.
EXPECTED_SHA512=""
if [ "${TAG}" = "v5.56.0" ]; then
    case "${ARCH}" in
        64) EXPECTED_SHA512="275e13a9ece84cbe38479e2fc9ba23939699f0b6250dc3aa659523294ec9bb8afadd86205e0b851575980191aed4373679b61a38ba842e58a36dcb69b193527a" ;;
        32) EXPECTED_SHA512="ee9fcd72f887447e3ba7ee80d55702862f47ea05433ab0bf668b71900e6982ed534a1984ecb0bafa43e33835dcffabc804e90d45102564ae2fad903482b491f8" ;;
        arm64-v8a) EXPECTED_SHA512="992082d7cd37db03147fab846dbc6b5ca47daa882b5808a0354586c6ae2ae4d399a8498dbc1152cf2ff46733f78ee06e762c98da24fa33904d614ded000934ac" ;;
        arm32-v7a) EXPECTED_SHA512="3bca433b504aefaf9b13f4be0b1527ad9f047ef0d7c187fa35c68f45c28c97449ce6fdc0fbb69ef4b075744165459f5180142693a5f86e83e770f26b5a982eff" ;;
        arm32-v6) EXPECTED_SHA512="e493ea5cc450a20fb3f2802dffe6d8b444ab1bc292122d4bdee5fad7fae703facc0cc360fd0ff55f8f0696ae62dd88a5584bbb8b20e18a0ea43f322052055791" ;;
        arm32-v5) EXPECTED_SHA512="1b1970afd7cce7b8ef0c48a227ea94aa5133a859065317131f288b9fd28086f73abac86acd8ded58e9754e166dbea36113c908c02985dd5b8abd489a156b9ce9" ;;
        loong64) EXPECTED_SHA512="5a666880530db0b437c7d5e5bd51dd44426ef3fd02531e72060fd525b9ab2b973ae1e903f75d48a2348525115a0004c0b0b5f339111b69ab848e2d8cd80896b4" ;;
        riscv64) EXPECTED_SHA512="90588f90d2344c0bbfa7e3ab7dc2f61cbbf0eae1a018f1c6118a377a400944f1b36aabbf7e6368d6383d93b94f942c6993eb05a0d71c809f0ed0232b261cd6df" ;;
        mips32) EXPECTED_SHA512="ddaa540c9b3f9a44eb6989a7d84b9a3b83eb9904f65ab0da7903ea02a554f51706d45db786e856abaaadfbe0fa2382a4594db3055c8a6abf04472ee24251fc80" ;;
        mips32le) EXPECTED_SHA512="55384335b5bc7be857cbef50768485049c80c4990fab8a593b29428bdf072aeaaa0a1fe8f61ad526c188d97fd3184bf304e8b6cc1366e1b6e27fd40a1edd609f" ;;
        mips64) EXPECTED_SHA512="bbba1c4b6c8eeec9e5b47125c1c7c459f9fbe7e6a5c3f17a261a4654ee35633ae79aa3d29e95f036bb3c2ee0df00385840d1c3d1e90cea2b5d107d569c52152a" ;;
        mips64le) EXPECTED_SHA512="e596c40ddea5ab48d8e3e53ef8c15dc1581739305eb87ac161f3642646ae321006038efcebf7633a79991abcd82ca30e19d3c18ec5c50aa97dcbc6d38b486571" ;;
    esac
fi
if [ -n "${EXPECTED_SHA512}" ] && { [ -z "${V2RAY_DOWNLOAD_BASE:-}" ] || [ "${V2RAY_ENFORCE_PINNED_HASH:-}" = "1" ]; }; then
    if [ "${LOCAL}" = "${EXPECTED_SHA512}" ]; then
        echo " Check passed (matches the pinned v5.56.0 SHA512)" && rm -fv v2ray.zip.dgst
    else
        echo " Check failed: SHA512 mismatch for v2ray.zip (does not match the pinned v5.56.0 hash)" && exit 1
    fi
else
    if [ -n "${EXPECTED_SHA512}" ]; then
        echo "Warning: V2RAY_DOWNLOAD_BASE is overridden; skipping the pinned SHA512 check and trusting the downloaded .dgst only" >&2
    else
        echo "Warning: no pinned SHA512 is known for ${TAG}; trusting the downloaded .dgst only" >&2
    fi
    echo " Check passed" && rm -fv v2ray.zip.dgst
fi

# Prepare
echo "Prepare to use"
# Defence in depth before unpacking: refuse any entry that would escape the
# download directory (an absolute path, or a parent-directory component).
# The .dgst check above only guards against transport corruption: the
# .dgst file comes from the same release as the zip, so it cannot prove
# the release itself was not tampered with. (The pinned-SHA512 check
# above closes that gap for the default upstream base; a custom
# V2RAY_DOWNLOAD_BASE still relies on the .dgst alone.)
# Entries are listed with `unzip -l`, not `unzip -Z1`: the Alpine image
# (and any BusyBox-based host) only has the BusyBox unzip applet, which
# has no -Z option -- `unzip -Z1` fails there with "unrecognized option:
# Z", aborting the install after the download and checksum already
# passed. `unzip -l` works on both BusyBox and Info-ZIP unzip with the
# same four-column layout (Length Date Time Name); keep only lines whose
# first field is a numeric length and take everything after the first
# three fields, so names containing spaces survive intact. (BusyBox
# lists names after its own strip_unsafe_prefix sanitising, and applies
# the same sanitising on extraction; Info-ZIP lists raw names, which the
# grep below catches.) The listing is written to a file first and then
# parsed, so a failed unzip is still detected -- a pipe would report
# awk's status instead, and POSIX sh has no pipefail.
if ! unzip -l v2ray.zip >"${DOWNLOAD_PATH}/zip-list.txt"; then
    fail "failed to list v2ray.zip"
fi
awk '$1 ~ /^[0-9]+$/ && NF >= 4 { $1=""; $2=""; $3=""; sub(/^ +/, ""); print }' \
    "${DOWNLOAD_PATH}/zip-list.txt" >"${DOWNLOAD_PATH}/zip-entries.txt" \
    || fail "failed to parse v2ray.zip listing"
if grep -Eq '(^|/)\.\.(/|$)|^/' "${DOWNLOAD_PATH}/zip-entries.txt"; then
    echo "Error: v2ray.zip contains an entry with an absolute path or a parent-directory component; refusing to unpack" >&2
    exit 1
fi
unzip -o v2ray.zip || fail "failed to unpack v2ray.zip"

# Refuse to install an incomplete file set: nothing under the install
# locations may change until every expected file is present.
# Upstream no longer ships v2ctl (removed in v2ray-core 5.x; neither the
# v5.53.0 nor the v5.56.0 archive contains it), so it is not required here.
# Each expected entry must also be a regular file, not a symlink: the
# zip-slip check above only inspects entry names, so a symlinked `v2ray`
# pointing at a system path would pass `[ -f ]` (which follows links),
# have its target's permissions changed by the chmod below, and be
# installed into BIN_DIR -- where the final exec would run the link
# target instead of v2ray. A compromised release is required to exploit
# this (same premise as M2), but refusing symlinks costs nothing.
for f in v2ray geosite.dat geoip.dat; do
    [ -f "${f}" ] || fail "downloaded archive is missing ${f}; refusing to install an incomplete file set"
    [ ! -L "${f}" ] || fail "downloaded archive contains a symbolic link for ${f}; refusing to install"
done
chmod +x v2ray || fail "failed to make v2ray executable"

mkdir -p "${BIN_DIR}" "${SHARE_DIR}" || fail "failed to prepare install directories"
CONFIG_DIR=$(dirname "${CONFIG_FILE}")
mkdir -p "${CONFIG_DIR}" || fail "failed to prepare config directory ${CONFIG_DIR}"
# The config holds the VMess UUID, the service's only credential, so its
# directory is owner-only (the "/" guard keeps a degenerate
# V2RAY_CONFIG_FILE override from chmodding the filesystem root).
if [ "${CONFIG_DIR}" != "/" ]; then
    chmod 700 "${CONFIG_DIR}" || fail "failed to restrict ${CONFIG_DIR} to 0700"
fi

# Back up everything this run may replace, before replacing anything.
for spec in "v2ray:${BIN_DIR}/v2ray" "geosite.dat:${SHARE_DIR}/geosite.dat" "geoip.dat:${SHARE_DIR}/geoip.dat" "config.json:${CONFIG_FILE}"; do
    name="${spec%%:*}"
    target="${spec#*:}"
    if [ -f "${target}" ]; then
        cp -f "${target}" "${BACKUP_DIR}/${name}" || fail "failed to back up ${target}"
    fi
done
INSTALL_STARTED=1

mv -f v2ray "${BIN_DIR}/" || fail "failed to install v2ray binary to ${BIN_DIR}"
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
# Restrict the temporary file BEFORE the rename, so the config is never
# readable by other local users -- not even in the window between a
# rename and a chmod of the target. Under the default umask 022 the
# config would otherwise land as 0644 with the UUID world-readable.
chmod 600 "${CONFIG_TMP}" || {
    rm -f "${CONFIG_TMP}"
    fail "failed to restrict ${CONFIG_TMP} to 0600"
}
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

# Install succeeded: no trap must roll anything back afterwards, and the
# temp dirs are no longer needed. A later v2ray runtime failure must not
# uninstall what was just installed -- and neither must a later signal,
# so all four traps go, not just EXIT.
trap - EXIT HUP INT TERM
cleanup

# Run v2ray (skipped by drills via V2RAY_SKIP_RUN=1). exec replaces this
# shell: xf.sh runs as PID 1 in the container, and a PID 1 shell does not
# forward signals to its children -- docker stop's SIGTERM would be
# ignored until the stop timeout and the container then SIGKILLed, with
# no graceful shutdown. After exec, v2ray itself is PID 1 and receives
# signals directly; the exit code is v2ray's either way.
if [ "${V2RAY_SKIP_RUN:-}" != "1" ]; then
    # v2ray 5.x is subcommand-based: bare `-config` is rejected with
    # "flag provided but not defined: -config" (exit 2). `run` is the
    # subcommand that starts the server with a config file.
    exec "${BIN_DIR}/v2ray" run -config "${CONFIG_FILE}"
fi
