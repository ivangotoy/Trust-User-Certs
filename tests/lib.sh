# tests/lib.sh - helpers for tests/run.sh (POSIX sh: bash --posix and busybox ash).
#
# Every test runs in its own fake device root under $TUC_WORK. The module scripts
# are copied into a fake module dir whose sh/common.sh sources the real one and
# then re-points every absolute device path into the fake root. Device tools
# (getprop, mount, nsenter, chcon, ...) are stubs first on PATH: they only log
# and keep a fake mount table, they never touch the host.

TUC_STUBS="$TUC_WORK/stubs"

# Fixture certificates (made up, no keys):
#   test-ca.pem   CN=TUC Test Root CA, subject_hash_old 49a507ae
#   other-ca.pem  CN=TUC Other CA,     subject_hash_old 6a1c5d49
TEST_HASH=49a507ae
OTHER_HASH=6a1c5d49

# Real tools the stubs forward to, resolved before the stubs go on PATH.
TUC_REAL_CP=$(command -v cp)
TUC_REAL_CHMOD=$(command -v chmod)

make_stubs() {
  mkdir -p "$TUC_STUBS"
  # getprop <name>: values come from the environment of the test.
  cat >"$TUC_STUBS/getprop" <<'EOF'
#!/bin/sh
case "$1" in
  ro.build.version.sdk) printf '%s\n' "${TUC_SDK:-33}" ;;
  sys.boot_completed) printf '%s\n' "${TUC_BOOT_COMPLETED:-1}" ;;
  *) printf '\n' ;;
esac
EOF
  cat >"$TUC_STUBS/getenforce" <<'EOF'
#!/bin/sh
printf '%s\n' "${TUC_ENFORCE:-Enforcing}"
EOF
  # mount: records the call and keeps $TUC_MOUNTS (a /proc/mounts look-alike).
  # A tmpfs mount empties the target (its old files move aside); a bind
  # mount makes the target show the source's files.
  cat >"$TUC_STUBS/mount" <<'EOF'
#!/bin/sh
printf 'mount %s\n' "$*" >>"$TUC_CALLS"
[ "${TUC_MOUNT_FAIL:-}" = all ] && exit 1
src="" dst="" kind=""
while [ $# -gt 0 ]; do
  case "$1" in
    -t) kind="$2"; shift 2 ;;
    -o) [ "$2" = bind ] && kind=bind; shift 2 ;;
    --bind) kind=bind; shift ;;
    *) if [ -z "$src" ]; then src="$1"; else dst="$1"; fi; shift ;;
  esac
done
[ -d "$dst" ] || exit 1
[ "${TUC_MOUNT_FAIL:-}" = bind ] && [ "$kind" = bind ] && exit 1
n=$(wc -l <"$TUC_MOUNTS" | tr -d ' ')
mkdir -p "$TUC_ROOT/.under/$n"
for f in "$dst"/* "$dst"/.[!.]*; do [ -e "$f" ] && mv "$f" "$TUC_ROOT/.under/$n/"; done
if [ "$kind" = bind ]; then
  for f in "$src"/*; do [ -e "$f" ] && "$TUC_REAL_CP" -p "$f" "$dst/"; done
fi
printf '%s %s %s rw 0 0 #%s\n' "$kind" "$dst" "$kind" "$n" >>"$TUC_MOUNTS"
exit 0
EOF
  # umount [-l] <dir>: pops the last mount on <dir> and restores what it hid.
  cat >"$TUC_STUBS/umount" <<'EOF'
#!/bin/sh
printf 'umount %s\n' "$*" >>"$TUC_CALLS"
[ "$1" = -l ] && shift
line=$(grep " $1 " "$TUC_MOUNTS" | tail -n 1)
[ -n "$line" ] || exit 1
n=${line##*#}
grep -v "#$n\$" "$TUC_MOUNTS" >"$TUC_MOUNTS.n"; mv "$TUC_MOUNTS.n" "$TUC_MOUNTS"
for f in "$1"/* "$1"/.[!.]*; do [ -e "$f" ] && rm -rf "$f"; done
for f in "$TUC_ROOT/.under/$n"/* "$TUC_ROOT/.under/$n"/.[!.]*; do [ -e "$f" ] && mv "$f" "$1/"; done
exit 0
EOF
  # Tools that must never act on the host: log and succeed.
  for t in nsenter chcon chown restorecon pkill; do
    printf '#!/bin/sh\nprintf "%s %%s\\n" "$*" >>"$TUC_CALLS"\nexit 0\n' "$t" >"$TUC_STUBS/$t"
  done
  # No process is ever detached from a test.
  for t in setsid nohup; do
    printf '#!/bin/sh\nprintf "%s %%s\\n" "$*" >>"$TUC_CALLS"\nexit 1\n' "$t" >"$TUC_STUBS/$t"
  done
  # pgrep zygote -> $TUC_ZYGOTE_PIDS (default: none).
  cat >"$TUC_STUBS/pgrep" <<'EOF'
#!/bin/sh
[ "$1" = zygote ] && [ -n "${TUC_ZYGOTE_PIDS:-}" ] && { printf '%s\n' $TUC_ZYGOTE_PIDS; exit 0; }
exit 1
EOF
  # sleep returns at once: waits and settle delays cost nothing.
  printf '#!/bin/sh\nexit 0\n' >"$TUC_STUBS/sleep"
  # cp: forwards to the real cp. TUC_CP_FAIL_DEST=<substring> makes a copy whose
  # destination (last argument) contains it fail - after copying only the
  # first source when TUC_CP_FAIL_MODE=partial (a full disk).
  cat >"$TUC_STUBS/cp" <<'EOF'
#!/bin/sh
last=""; for a in "$@"; do last="$a"; done
if [ -n "${TUC_CP_FAIL_DEST:-}" ]; then
  case "$last" in
    *"$TUC_CP_FAIL_DEST"*)
      if [ "${TUC_CP_FAIL_MODE:-}" = partial ]; then
        for a in "$@"; do
          case "$a" in -*) continue ;; esac
          [ -f "$a" ] && { "$TUC_REAL_CP" -f "$a" "$last"; break; }
        done
      fi
      exit 1
      ;;
  esac
fi
exec "$TUC_REAL_CP" "$@"
EOF
  # chmod: forwards to the real chmod and records each call.
  cat >"$TUC_STUBS/chmod" <<'EOF'
#!/bin/sh
printf 'chmod %s\n' "$*" >>"$TUC_CALLS"
exec "$TUC_REAL_CHMOD" "$@"
EOF
  for f in "$TUC_STUBS"/*; do "$TUC_REAL_CHMOD" 755 "$f"; done
}

# new_device [sdk] - fresh fake root, fake module dir and fake stock store.
new_device() {
  TUC_ROOT="$TUC_WORK/dev.$TUC_N"
  rm -rf "$TUC_ROOT"
  mkdir -p "$TUC_ROOT/data/adb/modules/trust-user-certs/sh" \
    "$TUC_ROOT/data/misc/user/0" \
    "$TUC_ROOT/system/etc/security/cacerts" \
    "$TUC_ROOT/apex/com.android.conscrypt/cacerts" \
    "$TUC_ROOT/mnt"
  TUC_MOD="$TUC_ROOT/data/adb/modules/trust-user-certs"
  TUC_MOUNTS="$TUC_ROOT/mounts"
  TUC_CALLS="$TUC_ROOT/calls"
  : >"$TUC_MOUNTS"
  : >"$TUC_CALLS"
  TUC_SDK="${1:-33}"
  export TUC_ROOT TUC_MOUNTS TUC_CALLS TUC_SDK TUC_REAL_CP TUC_REAL_CHMOD
  unset TUC_CP_FAIL_DEST TUC_CP_FAIL_MODE TUC_MOUNT_FAIL TUC_ZYGOTE_PIDS TUC_BOOT_COMPLETED
  "$TUC_REAL_CP" "$TUC_REPO/post-fs-data.sh" "$TUC_REPO/service.sh" "$TUC_REPO/module.prop" "$TUC_MOD/"
  "$TUC_REAL_CP" "$TUC_REPO/sh/inject.sh" "$TUC_MOD/sh/"
  cat >"$TUC_MOD/sh/common.sh" <<EOF
. "$TUC_REPO/sh/common.sh"
R="$TUC_ROOT"
DATA_DIR="\$R/data/adb/\$MODULE_ID"
CONFIG_FILE="\$DATA_DIR/config"
STATS_FILE="\$DATA_DIR/stats"
FAIL_FILE="\$DATA_DIR/boot_fail_count"
LOG_DIR="\$DATA_DIR/logs"
LOG_FILE="\$LOG_DIR/service.log"
LOCK_DIR="\$DATA_DIR/locks"
STATS_LOCK="\$LOCK_DIR/stats.lock"
CONFIG_LOCK="\$LOCK_DIR/config.lock"
SYNC_LOCK="\$LOCK_DIR/sync.lock"
WATCH_PID_FILE="\$DATA_DIR/watcher.pid"
INOTIFYD_PID_FILE="\$DATA_DIR/inotifyd.pid"
WATCH_FIFO="\$DATA_DIR/watch.fifo"
WATCH_ERR_FILE="\$DATA_DIR/inotifyd.err"
EXCLUDE_HASH_FILE="\$DATA_DIR/exclude_hashes"
EXCLUDE_SUBJ_FILE="\$DATA_DIR/exclude_subjects"
CERT_STAGE="\$DATA_DIR/cert_stage"
BASE_CERT_DIR="\$DATA_DIR/base_certs"
CUSTOM_CERT_DIR="\$DATA_DIR/certs"
LEGACY_CUSTOM_CERT_DIR="\$R/data/local/tmp/cert"
USER_CERT_DIR="\$R/data/misc/user/0/cacerts-added"
USER_CERT_PARENT="\${USER_CERT_DIR%/*}"
SYSTEM_CERT_DIR="\$R/system/etc/security/cacerts"
APEX_CONSCRYPT_DIR="\$R/apex/com.android.conscrypt/cacerts"
TEMP_MOUNT="\$R/mnt/tuc_stage"
is_mounted() { grep -q " \$1 " "\$TUC_MOUNTS" 2>/dev/null; }
EOF
  TUC_DATA="$TUC_ROOT/data/adb/trust-user-certs"
  TUC_USER="$TUC_ROOT/data/misc/user/0/cacerts-added"
  TUC_SYS="$TUC_ROOT/system/etc/security/cacerts"
  TUC_APEX="$TUC_ROOT/apex/com.android.conscrypt/cacerts"
  TUC_LOG="$TUC_DATA/logs/service.log"
  # A made-up stock store: three system certificates.
  for s in 0000000a 0000000b 0000000c; do
    printf 'stock %s\n' "$s" >"$TUC_SYS/$s.0"
    printf 'stock %s\n' "$s" >"$TUC_APEX/$s.0"
  done
  mkdir -p "$TUC_DATA"
  printf 'LIVE_SYNC=0\nLOG_LEVEL=2\n' >"$TUC_DATA/config"
}

# run_mod <script> [args...] - runs a module script from the fake module dir.
run_mod() {
  _rm_s="$1"
  shift
  sh "$TUC_MOD/$_rm_s" "$@"
}

# in_mod <shell code> - runs code with common.sh + inject.sh of the fake module.
in_mod() {
  sh -c ". \"$TUC_MOD/sh/common.sh\"; . \"$TUC_MOD/sh/inject.sh\"; $1"
}

user_cert() { # user_cert <fixture> <name>
  mkdir -p "$TUC_USER"
  "$TUC_REAL_CP" "$TUC_REPO/tests/fixtures/$1" "$TUC_USER/$2"
}

stat_of() { sed -n "s/^$1=//p" "$TUC_DATA/stats" 2>/dev/null | tail -n 1; }

# ── assertions ────────────────────────────────────────────────────────────────
fail() {
  printf '    FAIL: %s\n' "$*"
  TUC_TEST_FAILED=1
  return 1
}
assert_eq() { [ "$1" = "$2" ] || fail "$3: expected '$2', got '$1'"; }
assert_file() { [ -f "$1" ] || fail "$2: missing file ${1#"$TUC_ROOT"}"; }
assert_no_file() { [ ! -e "$1" ] || fail "$2: unexpected file ${1#"$TUC_ROOT"}"; }
assert_grep() { grep -q -- "$1" "$2" 2>/dev/null || fail "$3: '$1' not found in ${2##*/}"; }
assert_no_grep() { ! grep -q -- "$1" "$2" 2>/dev/null || fail "$3: '$1' found in ${2##*/}"; }
count() { _c=0; for _f in "$1"/*; do [ -f "$_f" ] && _c=$((_c + 1)); done; printf '%s' "$_c"; }
