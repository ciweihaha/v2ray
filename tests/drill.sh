#!/bin/bash
# Drills for xf.sh: fake-release install, zip-slip refusal, input
# validation, SHA-mismatch rollback. No network needed: a local
# python http.server serves a fabricated v2ray release.
#
# Usage: tests/drill.sh
#   BUSYBOX=/path/to/busybox  -- also exercise the BusyBox unzip listing
#   (Alpine image path). If unset and `busybox` is on PATH, that is used;
#   if no busybox is available the BusyBox cases are skipped.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
XF="$ROOT/xf.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/v2ray-drill.XXXXXX")"
PASS=0; FAIL=0; SKIP=0

ok()   { PASS=$((PASS+1)); echo "PASS: $*"; }
bad()  { FAIL=$((FAIL+1)); echo "FAIL: $*" >&2; }
skip() { SKIP=$((SKIP+1)); echo "SKIP: $*"; }

cleanup() { [ -n "${SRV:-}" ] && kill "$SRV" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT

# --- fixture builder: fake release dir with zip + correct .dgst ----------
# The zip bytes are built in memory and written via stdout redirection
# (works even where python file writes are restricted).
make_fixture() { # $1=outdir $2=mode(normal|slip|slip-space|badsha)
    local out="$1" mode="$2"
    mkdir -p "$out"
    python3 - "$mode" <<'PY' > "$out/v2ray-linux-64.zip"
import sys, zipfile, io
mode = sys.argv[1]
buf = io.BytesIO()
z = zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED)
for n in ("v2ray", "geosite.dat", "geoip.dat"):
    z.writestr(n, "fake-" + n)
if mode == "slip":
    z.writestr("../evil.sh", "echo pwned\n")
    z.writestr("/tmp/abs-evil.sh", "echo pwned\n")
    z.writestr("a/../../evil2.sh", "echo pwned\n")
elif mode == "slip-space":
    z.writestr("data dir/../../evil2.sh", "echo pwned\n")
z.close()
sys.stdout.buffer.write(buf.getvalue())
PY
    local sha
    sha="$(openssl dgst -sha512 "$out/v2ray-linux-64.zip" | awk '{print $NF}')"
    if [ "$mode" = "badsha" ]; then sha="00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"; fi
    printf 'SHA2-512= %s\n' "$sha" > "$out/v2ray-linux-64.zip.dgst"
}

# --- local fixture server ------------------------------------------------
PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
FIXROOT="$WORK/fixtures"; mkdir -p "$FIXROOT"
(cd "$FIXROOT" && exec python3 -m http.server "$PORT" >/dev/null 2>&1) &
SRV=$!
sleep 1

# --- run xf.sh with a clean env against one fixture ----------------------
# $1=fixture dir $2=work subdir $3..=extra env assignments (VAR=val)
run_xf() {
    local fix="$1" w="$2"; shift 2
    mkdir -p "$w/bin" "$w/share" "$w/etc"
    env -i PATH="/usr/bin:/bin" HOME="$HOME" \
        VMESS_UUID="11111111-2222-3333-4444-555555555555" \
        V2RAY_VERSION="v5.56.0" \
        V2RAY_DOWNLOAD_BASE="http://127.0.0.1:$PORT/$fix" \
        V2RAY_BIN_DIR="$w/bin" V2RAY_SHARE_DIR="$w/share" \
        V2RAY_CONFIG_FILE="$w/etc/config.json" \
        V2RAY_SKIP_RUN=1 TMPDIR="$w" \
        "$@" sh "$XF" >"$w/run.log" 2>&1
}

# --- 1. normal install ---------------------------------------------------
make_fixture "$FIXROOT/normal" normal
W1="$WORK/case1"
run_xf normal "$W1"; rc=$?
if [ "$rc" -eq 0 ] && [ -x "$W1/bin/v2ray" ] && [ -f "$W1/share/geosite.dat" ] \
   && [ -f "$W1/share/geoip.dat" ] && [ -f "$W1/etc/config.json" ]; then
    ok "normal install succeeds and installs all files"
else
    bad "normal install failed (rc=$rc)"; cat "$W1/run.log" >&2
fi
if python3 -c "import json; d=json.load(open('$W1/etc/config.json')); assert d['inbounds'][0]['settings']['clients'][0]['id']=='11111111-2222-3333-4444-555555555555'; assert d['inbounds'][0]['port']==8080" 2>/dev/null; then
    ok "installed config.json is valid JSON with the given UUID"
else
    bad "installed config.json is invalid or has the wrong UUID"
fi

# --- 2. zip-slip refused, pre-existing install untouched ------------------
make_fixture "$FIXROOT/slip" slip
W2="$WORK/case2"
mkdir -p "$W2/bin" "$W2/share" "$W2/etc"
printf 'OLD-BINARY' > "$W2/bin/v2ray"
printf 'OLD-CONFIG' > "$W2/etc/config.json"
run_xf slip "$W2"; rc=$?
if [ "$rc" -ne 0 ] && grep -q "refusing to unpack" "$W2/run.log"; then
    ok "zip-slip archive is refused before unpacking"
else
    bad "zip-slip archive was not refused (rc=$rc)"; cat "$W2/run.log" >&2
fi
if [ "$(cat "$W2/bin/v2ray")" = "OLD-BINARY" ] && [ "$(cat "$W2/etc/config.json")" = "OLD-CONFIG" ] \
   && [ ! -e "$WORK/evil.sh" ] && [ ! -e "$WORK/evil2.sh" ] \
   && [ ! -e "$W2/evil.sh" ] && [ ! -e "$W2/evil2.sh" ] && [ ! -e /tmp/abs-evil.sh ]; then
    ok "zip-slip attempt left the previous install untouched and escaped nothing"
else
    bad "zip-slip attempt changed files outside the download dir"
fi

# --- 3. traversal hidden after a space is refused ------------------------
make_fixture "$FIXROOT/slip-space" slip-space
W3="$WORK/case3"
run_xf slip-space "$W3"; rc=$?
if [ "$rc" -ne 0 ] && grep -q "refusing to unpack" "$W3/run.log"; then
    ok "traversal after a space in an entry name is refused"
else
    bad "spaced traversal was not refused (rc=$rc)"; cat "$W3/run.log" >&2
fi

# --- 4. SHA mismatch refused, previous install rolled back ---------------
make_fixture "$FIXROOT/badsha" badsha
W4="$WORK/case4"
mkdir -p "$W4/bin" "$W4/share" "$W4/etc"
printf 'OLD-BINARY' > "$W4/bin/v2ray"
run_xf badsha "$W4"; rc=$?
if [ "$rc" -ne 0 ] && grep -qi "SHA512 mismatch" "$W4/run.log" \
   && [ "$(cat "$W4/bin/v2ray")" = "OLD-BINARY" ]; then
    ok "SHA512 mismatch aborts and keeps the previous binary"
else
    bad "SHA mismatch handling wrong (rc=$rc)"; cat "$W4/run.log" >&2
fi

# --- 5. input validation --------------------------------------------------
check_reject() { # $1=label, $2..=extra env
    local label="$1"; shift
    local w="$WORK/reject-$RANDOM"
    run_xf normal "$w" "$@"; local rc=$?
    if [ "$rc" -ne 0 ]; then ok "$label rejected (rc=$rc)"; else bad "$label was NOT rejected"; fi
}
# The unset case is tested by invoking xf.sh directly (run_xf always
# sets VMESS_UUID):
env -i PATH="/usr/bin:/bin" sh "$XF" >"$WORK/reject-nouuid.log" 2>&1; rc=$?
if [ "$rc" -ne 0 ] && grep -q "VMESS_UUID is not set" "$WORK/reject-nouuid.log"; then
    ok "unset VMESS_UUID rejected with a clear error"
else
    bad "unset VMESS_UUID was not rejected (rc=$rc)"
fi
check_reject "non-hex UUID" VMESS_UUID="11111111-2222-3333-4444-55555555555z"
check_reject "UUID without hyphens" VMESS_UUID="11111111222233334444555555555555"
check_reject "short UUID" VMESS_UUID="11111111-2222-3333-4444"
check_reject "non-release V2RAY_VERSION" V2RAY_VERSION="latest"
# NOTE: a version with shell metacharacters (e.g. 'v1.2.3; rm -rf /') is
# NOT asserted here: with V2RAY_DOWNLOAD_BASE overridden the version
# never reaches a URL in this drill, so the install would succeed. In
# real use the version only enters the default GitHub URL and a weird
# version fails the download (fail-closed). Tightening the version
# pattern itself is a separate hardening item, not this drill's job.

# --- 6. BusyBox unzip listing (Alpine image path) -------------------------
BB="${BUSYBOX:-$(command -v busybox || true)}"
if [ -z "$BB" ]; then
    skip "no busybox binary available; BusyBox listing cases skipped"
else
    # The original bug: BusyBox unzip has no -Z option.
    if "$BB" unzip -Z1 "$FIXROOT/normal/v2ray-linux-64.zip" >/dev/null 2>&1; then
        bad "busybox unzip -Z1 unexpectedly works (bug repro invalid)"
    else
        ok "busybox unzip -Z1 fails as expected (this is the bug xf.sh used to hit)"
    fi
    # The fix: `unzip -l` lists the same entries on BusyBox and Info-ZIP.
    LIST="$WORK/bb-list.txt"
    if "$BB" unzip -l "$FIXROOT/normal/v2ray-linux-64.zip" 2>/dev/null \
        | awk '$1 ~ /^[0-9]+$/ && NF >= 4 { $1=""; $2=""; $3=""; sub(/^ +/, ""); print }' > "$LIST" \
        && grep -qx "v2ray" "$LIST" && grep -qx "geosite.dat" "$LIST" && grep -qx "geoip.dat" "$LIST"; then
        ok "busybox unzip -l listing parses to the expected entry names"
    else
        bad "busybox unzip -l listing did not parse"; cat "$LIST" >&2
    fi
    # BusyBox sanitises entry names on listing AND extraction, so a slip
    # archive must not escape even if it passed the listing check: extract
    # it and assert nothing lands outside the target dir. This needs a
    # busybox that can write files; some sandboxes block that.
    if "$BB" sh -c 'echo x > "$1"' _ "$WORK/bb-write-probe" 2>/dev/null && [ -s "$WORK/bb-write-probe" ]; then
        rm -rf "$WORK/bb-extract"; mkdir -p "$WORK/bb-extract"
        "$BB" unzip -o -q "$FIXROOT/slip/v2ray-linux-64.zip" -d "$WORK/bb-extract" 2>/dev/null
        if [ ! -s "$WORK/bb-extract/v2ray" ]; then
            skip "busybox extraction wrote nothing here; cannot verify the escape check"
        elif [ ! -e "$WORK/evil.sh" ] && [ ! -e "$WORK/bb-extract/../evil.sh" ] \
           && [ ! -e "$WORK/evil2.sh" ] && [ ! -e "/tmp/abs-evil.sh" ]; then
            ok "busybox extraction of a slip archive escapes nothing"
        else
            bad "busybox extraction of a slip archive escaped the target dir"
        fi
    else
        skip "busybox cannot write files here; busybox extraction case skipped"
    fi
fi

echo "drill: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
