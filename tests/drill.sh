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

cleanup() {
    [ -n "${SRV:-}" ] && kill "$SRV" 2>/dev/null
    [ -n "${BHSRV:-}" ] && kill "$BHSRV" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

# --- fixture builder: fake release dir with zip + correct .dgst ----------
# The zip bytes are built in memory and written via stdout redirection
# (works even where python file writes are restricted).
make_fixture() { # $1=outdir $2=mode(normal|slip|slip-space|badsha|exec) $3=arch suffix (default 64)
    local out="$1" mode="$2" arch="${3:-64}"
    mkdir -p "$out"
    python3 - "$mode" <<'PY' > "$out/v2ray-linux-$arch.zip"
import sys, zipfile, io
mode = sys.argv[1]
buf = io.BytesIO()
z = zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED)
for n in ("v2ray", "geosite.dat", "geoip.dat"):
    if mode == "symlink" and n == "v2ray":
        continue  # added below as a symlink entry, not a regular file
    if mode == "exec" and n == "v2ray":
        # A stand-in v2ray that records its own PID/PPID and arguments
        # and exits with a chosen code, so the drill can prove exec
        # replaced the shell and passed the right subcommand.
        z.writestr(n, "#!/bin/sh\necho \"$$ $PPID\" > \"${V2RAY_PID_FILE:-/dev/null}\"\necho \"$*\" > \"${V2RAY_ARGS_FILE:-/dev/null}\"\nexit \"${V2RAY_FAKE_EXIT:-0}\"\n")
    else:
        z.writestr(n, "fake-" + n)
if mode == "symlink":
    # A symlink entry for `v2ray` pointing at a system path: xf.sh must
    # refuse to install it instead of following the link.
    zi = zipfile.ZipInfo("v2ray")
    zi.create_system = 3  # Unix, so external_attr is honoured
    zi.external_attr = (0o120777 << 16)
    z.writestr(zi, "/bin/true")
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
    sha="$(openssl dgst -sha512 "$out/v2ray-linux-$arch.zip" | awk '{print $NF}')"
    if [ "$mode" = "badsha" ]; then sha="00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"; fi
    printf 'SHA2-512= %s\n' "$sha" > "$out/v2ray-linux-$arch.zip.dgst"
}

# --- local fixture server ------------------------------------------------
# Bind-then-close port picking races with other processes: the chosen
# port can be taken before the server binds. Start the server and
# verify it is actually listening, retrying on a fresh port if the
# bind lost the race.
free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'; }
port_open() { python3 -c 'import socket,sys; s=socket.socket(); sys.exit(0 if s.connect_ex(("127.0.0.1",int(sys.argv[1])))==0 else 1)' "$1"; }
FIXROOT="$WORK/fixtures"; mkdir -p "$FIXROOT"
SRV=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
    PORT="$(free_port)"
    (cd "$FIXROOT" && exec python3 -m http.server "$PORT" >/dev/null 2>&1) &
    SRV=$!
    sleep 0.5
    if kill -0 "$SRV" 2>/dev/null && port_open "$PORT"; then
        break
    fi
    kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null; SRV=""
done
[ -n "$SRV" ] || { echo "drill: failed to start fixture server" >&2; exit 1; }

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
if [ "$(stat -c %a "$W1/etc/config.json")" = "600" ] && [ "$(stat -c %a "$W1/etc")" = "700" ]; then
    ok "installed config.json is mode 600 and its directory is mode 700"
else
    bad "installed config permissions wrong (config=$(stat -c %a "$W1/etc/config.json" 2>/dev/null), dir=$(stat -c %a "$W1/etc" 2>/dev/null))"
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

# --- 3b. symlink entries are refused --------------------------------------
make_fixture "$FIXROOT/symlink" symlink
W3b="$WORK/case3b"
run_xf symlink "$W3b"; rc=$?
if [ "$rc" -ne 0 ] && grep -q "symbolic link" "$W3b/run.log"; then
    ok "archive with a symlinked v2ray binary is refused"
else
    bad "symlink archive was not refused (rc=$rc)"; cat "$W3b/run.log" >&2
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

# --- 4b. pinned SHA512 is enforced when requested -------------------------
# The fake zip's hash differs from the pinned v5.56.0 value, so forcing
# the pinned check must reject it even though its .dgst matches.
W4b="$WORK/case4b"
run_xf normal "$W4b" V2RAY_ENFORCE_PINNED_HASH=1; rc=$?
if [ "$rc" -ne 0 ] && grep -q "does not match the pinned" "$W4b/run.log"; then
    ok "pinned SHA512 check rejects a zip whose hash differs from the pinned v5.56.0 value"
else
    bad "pinned SHA512 check did not reject the fake zip (rc=$rc)"; cat "$W4b/run.log" >&2
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
check_reject "V2RAY_VERSION with shell metacharacters" V2RAY_VERSION='v1.2.3; rm -rf /'
check_reject "V2RAY_VERSION with a slash" V2RAY_VERSION='v5.56.0/../../x'
check_reject "oversized V2RAY_DOWNLOAD_TIMEOUT" V2RAY_DOWNLOAD_TIMEOUT=999999999

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
    # "$1" must expand in the inner busybox sh, not in this shell.
    # shellcheck disable=SC2016
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

# --- 7. v2ray replaces the shell (exec) ----------------------------------
# xf.sh runs as PID 1 in the container; without exec, v2ray would be a
# child of the PID 1 shell and never see docker stop's SIGTERM. With
# exec, the fake v2ray's PID must equal the xf.sh process PID, and its
# exit code must propagate as the script's exit code.
make_fixture "$FIXROOT/exec" exec
W7="$WORK/case7"; mkdir -p "$W7/bin" "$W7/share" "$W7/etc"
env -i PATH="/usr/bin:/bin" HOME="$HOME" \
    VMESS_UUID="11111111-2222-3333-4444-555555555555" \
    V2RAY_VERSION="v5.56.0" \
    V2RAY_DOWNLOAD_BASE="http://127.0.0.1:$PORT/exec" \
    V2RAY_BIN_DIR="$W7/bin" V2RAY_SHARE_DIR="$W7/share" \
    V2RAY_CONFIG_FILE="$W7/etc/config.json" \
    V2RAY_PID_FILE="$W7/pids" V2RAY_ARGS_FILE="$W7/args" V2RAY_FAKE_EXIT=42 \
    TMPDIR="$W7" \
    sh "$XF" >"$W7/run.log" 2>&1 &
XF_PID=$!
wait "$XF_PID"; rc=$?
if [ -f "$W7/pids" ]; then
    read -r vpid vppid < "$W7/pids"
    if [ "$vpid" = "$XF_PID" ]; then
        ok "v2ray execs in place of the shell (fake v2ray PID $vpid == xf.sh PID $XF_PID)"
    else
        bad "v2ray did not replace the shell (fake v2ray PID $vpid, PPID $vppid, xf.sh PID $XF_PID)"
    fi
    if [ "$rc" -eq 42 ]; then
        ok "v2ray exit code propagates (42)"
    else
        bad "v2ray exit code did not propagate (got $rc, want 42)"
    fi
    # v2ray 5.x needs the `run` subcommand; bare `-config` is rejected
    # with "flag provided but not defined: -config" (exit 2).
    if [ -f "$W7/args" ] && [ "$(cat "$W7/args")" = "run -config $W7/etc/config.json" ]; then
        ok "v2ray is started as 'run -config <config>' (v2ray 5.x subcommand form)"
    else
        bad "v2ray was started with the wrong arguments: $(cat "$W7/args" 2>/dev/null)"
    fi
else
    bad "fake v2ray never ran (rc=$rc)"; cat "$W7/run.log" >&2
fi

# --- 8. architecture detection --------------------------------------------
# 8a. V2RAY_ARCH override fetches the matching upstream zip.
make_fixture "$FIXROOT/arm64" normal arm64-v8a
W8a="$WORK/case8a"
run_xf arm64 "$W8a" V2RAY_ARCH=arm64-v8a; rc=$?
if [ "$rc" -eq 0 ] && [ -x "$W8a/bin/v2ray" ]; then
    ok "V2RAY_ARCH=arm64-v8a installs the arm64-v8a zip"
else
    bad "V2RAY_ARCH=arm64-v8a install failed (rc=$rc)"; cat "$W8a/run.log" >&2
fi
# 8b. Unknown architecture fails closed with a clear error.
W8b="$WORK/case8b"
run_xf normal "$W8b" V2RAY_ARCH=sparc64; rc=$?
if [ "$rc" -ne 0 ] && grep -q "unsupported CPU architecture" "$W8b/run.log"; then
    ok "unknown V2RAY_ARCH fails closed with a clear error"
else
    bad "unknown V2RAY_ARCH was not rejected (rc=$rc)"; cat "$W8b/run.log" >&2
fi
# 8c. uname -m detection: a fake uname reporting aarch64 (no override).
W8c="$WORK/case8c"; mkdir -p "$W8c/bin" "$W8c/share" "$W8c/etc" "$W8c/fakebin"
printf '#!/bin/sh\necho aarch64\n' > "$W8c/fakebin/uname"; chmod +x "$W8c/fakebin/uname"
env -i PATH="$W8c/fakebin:/usr/bin:/bin" HOME="$HOME" \
    VMESS_UUID="11111111-2222-3333-4444-555555555555" \
    V2RAY_VERSION="v5.56.0" \
    V2RAY_DOWNLOAD_BASE="http://127.0.0.1:$PORT/arm64" \
    V2RAY_BIN_DIR="$W8c/bin" V2RAY_SHARE_DIR="$W8c/share" \
    V2RAY_CONFIG_FILE="$W8c/etc/config.json" \
    V2RAY_SKIP_RUN=1 TMPDIR="$W8c" \
    sh "$XF" >"$W8c/run.log" 2>&1; rc=$?
if [ "$rc" -eq 0 ] && [ -x "$W8c/bin/v2ray" ]; then
    ok "uname -m aarch64 detects arm64-v8a and installs it"
else
    bad "uname -m detection failed (rc=$rc)"; cat "$W8c/run.log" >&2
fi

# --- 9. stalled download is bounded in time ------------------------------
# A server that accepts the connection and then never sends anything.
# With V2RAY_DOWNLOAD_TIMEOUT=5 the run must fail in seconds, not hang
# (GNU wget would otherwise retry a stalled download for minutes).
BHSRV=""
for _ in 1 2 3 4 5; do
    BHPORT="$(free_port)"
    python3 -c 'import socket,time,sys; s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR,1); s.bind(("127.0.0.1",int(sys.argv[1]))); s.listen(5)
while True:
    c,_=s.accept(); time.sleep(120)' "$BHPORT" >/dev/null 2>&1 &
    BHSRV=$!
    sleep 0.5
    if kill -0 "$BHSRV" 2>/dev/null && port_open "$BHPORT"; then
        break
    fi
    kill "$BHSRV" 2>/dev/null; wait "$BHSRV" 2>/dev/null; BHSRV=""
done
if [ -z "$BHSRV" ]; then
    bad "could not start the blackhole server; stalled-download case skipped"
else
W9="$WORK/case9"; mkdir -p "$W9/bin" "$W9/share" "$W9/etc"
START="$(date +%s)"
env -i PATH="/usr/bin:/bin" HOME="$HOME" \
    VMESS_UUID="11111111-2222-3333-4444-555555555555" \
    V2RAY_VERSION="v5.56.0" \
    V2RAY_DOWNLOAD_BASE="http://127.0.0.1:$BHPORT" \
    V2RAY_BIN_DIR="$W9/bin" V2RAY_SHARE_DIR="$W9/share" \
    V2RAY_CONFIG_FILE="$W9/etc/config.json" \
    V2RAY_SKIP_RUN=1 V2RAY_DOWNLOAD_TIMEOUT=5 TMPDIR="$W9" \
    sh "$XF" >"$W9/run.log" 2>&1; rc=$?
ELAPSED="$(( $(date +%s) - START ))"
kill "$BHSRV" 2>/dev/null
if [ "$rc" -ne 0 ] && grep -q "Failed to download" "$W9/run.log" \
   && [ "$ELAPSED" -ge 3 ] && [ "$ELAPSED" -le 30 ]; then
    ok "stalled download fails after the timeout instead of hanging (${ELAPSED}s)"
else
    bad "stalled download handling wrong (rc=$rc, ${ELAPSED}s)"; cat "$W9/run.log" >&2
fi
fi # blackhole server started
# A non-numeric timeout is rejected at validation, before any download.
W9b="$WORK/case9b"
run_xf normal "$W9b" V2RAY_DOWNLOAD_TIMEOUT="5m"; rc=$?
if [ "$rc" -ne 0 ] && grep -q "V2RAY_DOWNLOAD_TIMEOUT must be a number" "$W9b/run.log"; then
    ok "non-numeric V2RAY_DOWNLOAD_TIMEOUT rejected with a clear error"
else
    bad "non-numeric V2RAY_DOWNLOAD_TIMEOUT was not rejected (rc=$rc)"; cat "$W9b/run.log" >&2
fi
# A zero timeout is rejected too: GNU timeout treats 0 as "no timeout",
# so it would silently remove the bound instead of capping the download.
# Reverse control: case 9 above proves a real bound (5) works.
for zero in 0 00; do
    W9c="$WORK/case9c-$zero"
    run_xf normal "$W9c" V2RAY_DOWNLOAD_TIMEOUT="$zero"; rc=$?
    if [ "$rc" -ne 0 ] && grep -q "V2RAY_DOWNLOAD_TIMEOUT must be at least 1 second" "$W9c/run.log"; then
        ok "zero V2RAY_DOWNLOAD_TIMEOUT ($zero) rejected with a clear error"
    else
        bad "zero V2RAY_DOWNLOAD_TIMEOUT ($zero) was not rejected (rc=$rc)"; cat "$W9c/run.log" >&2
    fi
done

# --- 10. missing helper is reported clearly, before anything else ------
check_missing_tool() { # $1=tool to omit from PATH
    local tool="$1"
    local w="$WORK/missing-$tool" fakebin="$WORK/missing-$tool/fakebin"
    mkdir -p "$fakebin" "$w/bin" "$w/share" "$w/etc"
    for d in /usr/bin /bin; do
        for f in "$d"/*; do
            b="$(basename "$f")"
            [ "$b" = "$tool" ] && continue
            [ -e "$fakebin/$b" ] || ln -s "$f" "$fakebin/$b" 2>/dev/null
        done
    done
    env -i PATH="$fakebin" HOME="$HOME" \
        VMESS_UUID="11111111-2222-3333-4444-555555555555" \
        sh "$XF" >"$w/run.log" 2>&1; local rc=$?
    if [ "$rc" -ne 0 ] && grep -q "required command '$tool' is not installed" "$w/run.log"; then
        ok "missing $tool is reported clearly before anything else"
    else
        bad "missing $tool was not reported clearly (rc=$rc)"; cat "$w/run.log" >&2
    fi
}
check_missing_tool wget
check_missing_tool unzip
check_missing_tool timeout
check_missing_tool openssl

# --- 11. signal mid-install rolls back ------------------------------------
# A slow `mv` wrapper stretches the install phase (after backups, so
# INSTALL_STARTED=1 and the binary has already been replaced) into a
# window the drill can signal. The wrapper is slow only on its first
# call, so the rollback's own mv calls stay fast. The drill waits for
# the flag file the wrapper touches, so the signal reliably lands
# inside the install, not during the download.
check_signal() { # $1=signal name $2=expected exit code
    local sig="$1" want="$2"
    local w="$WORK/sig-$sig"
    mkdir -p "$w/bin" "$w/share" "$w/etc" "$w/fakebin"
    printf 'OLD-BINARY' > "$w/bin/v2ray"
    printf 'OLD-CONFIG' > "$w/etc/config.json"
    # "$@" and "$SLOWMV_FLAG" must expand in the wrapper, not here.
    # shellcheck disable=SC2016
    printf '#!/bin/sh\nif [ -e "$SLOWMV_FLAG" ]; then exec /bin/mv "$@"; fi\ntouch "$SLOWMV_FLAG"\nsleep 10\nexec /bin/mv "$@"\n' > "$w/fakebin/mv"
    chmod +x "$w/fakebin/mv"
# xf.sh is launched through python, not with `&`: a non-interactive
# shell starts background jobs with SIGINT ignored, and an ignored
# signal cannot be trapped -- the INT case would be vacuous. python's
# subprocess restores SIGINT to its default in the child, which is
# what a real foreground run (or PID 1 in the container) looks like.
    python3 - "$XF" "$w" "$PORT" >"$w/pid" 2>"$w/py.log" <<'PY' &
import os, subprocess, sys, signal
xf, w, port = sys.argv[1], sys.argv[2], sys.argv[3]
# The launcher itself runs as a background job, so it inherits SIGINT
# ignored -- and an ignored signal stays ignored across exec, which
# would make the INT trap untestable. Reset it here so the child sh
# starts with SIGINT at its default, as in a real foreground run.
signal.signal(signal.SIGINT, signal.SIG_DFL)
env = {
    "PATH": w + "/fakebin:/usr/bin:/bin",
    "HOME": os.environ["HOME"],
    "VMESS_UUID": "11111111-2222-3333-4444-555555555555",
    "V2RAY_VERSION": "v5.56.0",
    "V2RAY_DOWNLOAD_BASE": "http://127.0.0.1:" + port + "/normal",
    "V2RAY_BIN_DIR": w + "/bin",
    "V2RAY_SHARE_DIR": w + "/share",
    "V2RAY_CONFIG_FILE": w + "/etc/config.json",
    "V2RAY_SKIP_RUN": "1",
    "TMPDIR": w,
    "SLOWMV_FLAG": w + "/slowmv-started",
}
out = open(w + "/run.log", "wb")
p = subprocess.Popen(["sh", xf], env=env, stdout=out, stderr=subprocess.STDOUT)
print(p.pid, flush=True)
sys.exit(p.wait())
PY
    local launcher=$!
    local xpid=""
    for _ in $(seq 1 100); do
        [ -s "$w/pid" ] && xpid="$(cat "$w/pid")" && break
        sleep 0.2
    done
    [ -n "$xpid" ] || { bad "signal $sig test: launcher never reported the xf.sh PID"; cat "$w/py.log" >&2; return; }
    for _ in $(seq 1 100); do
        [ -e "$w/slowmv-started" ] && break
        sleep 0.2
    done
    if [ ! -e "$w/slowmv-started" ]; then
        bad "signal $sig test never reached the install phase"; kill "$xpid" 2>/dev/null; return
    fi
    kill "-$sig" "$xpid"
    wait "$launcher"; local rc=$?
    if [ "$rc" -eq "$want" ] && [ "$(cat "$w/bin/v2ray")" = "OLD-BINARY" ] \
       && [ "$(cat "$w/etc/config.json")" = "OLD-CONFIG" ] \
       && [ -z "$(find "$w" -maxdepth 1 -name 'v2ray*' -o -maxdepth 1 -name 'v2ray-backup*' | head -n1)" ] \
       && ! grep -q "Install done" "$w/run.log"; then
        ok "SIG$sig mid-install rolls back, cleans up and exits $want"
    else
        bad "SIG$sig mid-install handling wrong (rc=$rc)"; cat "$w/run.log" >&2
    fi
}
check_signal TERM 143
check_signal INT 130
check_signal HUP 129

# --- 12. container entrypoint writes config and execs v2ray ---------------
W12="$WORK/case12"; mkdir -p "$W12/bin" "$W12/etc"
printf '#!/bin/sh\necho "$$ $PPID" > "%s/pids"\necho "$*" > "%s/args"\nexit "${V2RAY_FAKE_EXIT:-0}"\n' "$W12" "$W12" > "$W12/bin/v2ray"
chmod +x "$W12/bin/v2ray"
env -i PATH="/usr/bin:/bin" HOME="$HOME" \
    VMESS_UUID="11111111-2222-3333-4444-555555555555" \
    V2RAY_BIN_DIR="$W12/bin" V2RAY_CONFIG_FILE="$W12/etc/config.json" \
    V2RAY_FAKE_EXIT=7 \
    sh "$ROOT/entrypoint.sh" >"$W12/run.log" 2>&1 &
EP_PID=$!
wait "$EP_PID"; rc=$?
if [ "$rc" -eq 7 ] && [ -f "$W12/pids" ] && [ "$(cut -d' ' -f1 "$W12/pids")" = "$EP_PID" ] \
   && [ "$(stat -c %a "$W12/etc/config.json")" = "600" ] \
   && [ -f "$W12/args" ] && [ "$(cat "$W12/args")" = "run -config $W12/etc/config.json" ] \
   && python3 -c "import json; d=json.load(open('$W12/etc/config.json')); assert d['inbounds'][0]['settings']['clients'][0]['id']=='11111111-2222-3333-4444-555555555555'" 2>/dev/null; then
    ok "entrypoint writes a mode-600 config with the UUID and execs 'v2ray run -config' in place (exit code propagates)"
else
    bad "entrypoint handling wrong (rc=$rc, args=$(cat "$W12/args" 2>/dev/null))"; cat "$W12/run.log" >&2
fi
env -i PATH="/usr/bin:/bin" sh "$ROOT/entrypoint.sh" >"$W12/nouuid.log" 2>&1; rc=$?
if [ "$rc" -ne 0 ] && grep -q "VMESS_UUID is not set" "$W12/nouuid.log"; then
    ok "entrypoint refuses to start without VMESS_UUID"
else
    bad "entrypoint without VMESS_UUID was not rejected (rc=$rc)"
fi

echo "drill: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
