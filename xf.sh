#!/bin/sh
##

# Set ARG
# The VMess client UUID must come from the environment. Fail closed when unset:
if [ -z "${VMESS_UUID:-}" ]; then
    echo "Error: VMESS_UUID is not set; refusing to write a v2ray config without an explicit UUID" >&2
    exit 1
fi

ARCH="64"
DOWNLOAD_PATH="/tmp/v2ray"

mkdir -p ${DOWNLOAD_PATH}
cd ${DOWNLOAD_PATH} || exit

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
echo "Downloading binary file: ${V2RAY_FILE}"
echo "Downloading binary file: ${DGST_FILE}"

# TAG=$(wget -qO- https://raw.githubusercontent.com/v2fly/docker/master/ReleaseTag | head -n1)
wget -O ${DOWNLOAD_PATH}/v2ray.zip https://github.com/v2fly/v2ray-core/releases/download/${TAG}/${V2RAY_FILE} >/dev/null 2>&1
wget -O ${DOWNLOAD_PATH}/v2ray.zip.dgst https://github.com/v2fly/v2ray-core/releases/download/${TAG}/${DGST_FILE} >/dev/null 2>&1

if [ $? -ne 0 ]; then
    echo "Error: Failed to download binary file: ${V2RAY_FILE} ${DGST_FILE}" && exit 1
fi
echo "Download binary file: ${V2RAY_FILE} ${DGST_FILE} completed"

# Check SHA512
# Compare hex digests only: openssl prints "SHA2-512(v2ray.zip)= <hex>" while the
# .dgst file has lines like "SHA512 (v2ray-linux-64.zip) = <hex>"; comparing full
# strings never matched, so the check always failed. (NOTE: this logic was not
# exercised inside a container for this patch; verify on a real run before use.)
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
unzip v2ray.zip && chmod +x v2ray v2ctl
mv v2ray v2ctl /usr/bin/
mv geosite.dat geoip.dat /usr/local/share/v2ray/
# mv config.json /etc/v2ray/config.json

# Set config file
cat <<EOF >/etc/v2ray/config.json
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

# Clean
cd ~ || return
rm -rf ${DOWNLOAD_PATH:?}/*
echo "Install done"

echo "--------------------------------"
echo "Fly App Name: ${FLY_APP_NAME}"
echo "Fly App Region: ${FLY_REGION}"
echo "V2Ray UUID: <from VMESS_UUID env; not printed>"
echo "--------------------------------"

# Run v2ray
/usr/bin/v2ray -config /etc/v2ray/config.json
