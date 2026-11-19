#!/bin/sh
# tests/run.sh - dependency-free checks for the module (POSIX sh).
#
#   sh tests/run.sh             syntax, JSON, YAML and behaviour tests
#   sh tests/run.sh --ash-only  the same without the host-only checks (bash -n
#                               of the CI script, JSON, YAML) - for a busybox
#                               ash pass, e.g. in an alpine container
#
# Scratch goes to $TMPDIR. Device tools are stubs; nothing outside the scratch
# dir is written, nothing is mounted, nothing is detached, and a test signals
# only the child processes it started itself.

TUC_REPO=$(cd "$(dirname "$0")/.." && pwd)
ASH_ONLY=0
[ "${1:-}" = --ash-only ] && ASH_ONLY=1

TUC_WORK=$(mktemp -d "${TMPDIR:-/tmp}/tuc-tests.XXXXXX") || exit 1
trap 'rm -rf "$TUC_WORK"' EXIT
export TUC_REPO TUC_WORK

PASS=0
FAILED=0
SKIP=0
ok() { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
ko() { FAILED=$((FAILED + 1)); printf 'FAIL %s\n' "$1"; }
skip() { SKIP=$((SKIP + 1)); printf 'skip %s\n' "$1"; }

cd "$TUC_REPO" || exit 1

# -- Syntax --
for f in customize.sh post-fs-data.sh service.sh uninstall.sh sh/*.sh \
  META-INF/com/google/android/update-binary tests/*.sh tests/cases/*.sh; do
  [ -f "$f" ] || continue
  if sh -n "$f" 2>"$TUC_WORK/err"; then ok "sh -n $f"; else ko "sh -n $f: $(cat "$TUC_WORK/err")"; fi
done

# Device shells: the root manager and the WebUI may run the module scripts
# under mksh or toybox sh. Checked when one is installed, else one skip each.
MODULE_SH="customize.sh post-fs-data.sh service.sh uninstall.sh sh/common.sh sh/inject.sh"
if command -v mksh >/dev/null 2>&1; then
  for f in $MODULE_SH; do
    if mksh -n "$f" 2>"$TUC_WORK/err"; then ok "mksh -n $f"; else ko "mksh -n $f: $(cat "$TUC_WORK/err")"; fi
  done
else
  skip "mksh -n (no mksh)"
fi
if command -v toybox >/dev/null 2>&1 && toybox sh -c : >/dev/null 2>&1; then
  for f in $MODULE_SH; do
    if toybox sh -n "$f" 2>"$TUC_WORK/err"; then ok "toybox sh -n $f"; else ko "toybox sh -n $f: $(cat "$TUC_WORK/err")"; fi
  done
else
  skip "toybox sh -n (no toybox sh)"
fi

if [ "$ASH_ONLY" = 1 ]; then
  skip "bash -n .forgejo/module-ci.sh, JSON, YAML (host-only)"
else
  if command -v bash >/dev/null 2>&1; then
    if bash -n .forgejo/module-ci.sh 2>"$TUC_WORK/err"; then ok "bash -n .forgejo/module-ci.sh"; else ko "bash -n .forgejo/module-ci.sh: $(cat "$TUC_WORK/err")"; fi
  else
    skip "bash -n .forgejo/module-ci.sh (no bash)"
  fi
  if command -v python3 >/dev/null 2>&1; then
    for f in update.json .forgejo/update.json; do
      if python3 -I -c 'import json,sys; json.load(open(sys.argv[1]))' "$f" 2>"$TUC_WORK/err"; then ok "json $f"; else ko "json $f: $(tail -n 1 "$TUC_WORK/err")"; fi
    done
    if python3 -I -c 'import yaml' 2>/dev/null; then
      for f in .forgejo/workflows/*.yml; do
        if python3 -I -c 'import yaml,sys; yaml.safe_load(open(sys.argv[1]))' "$f" 2>"$TUC_WORK/err"; then ok "yaml $f"; else ko "yaml $f: $(tail -n 1 "$TUC_WORK/err")"; fi
      done
    else
      skip "yaml (python3 has no yaml module)"
    fi
  else
    skip "json, yaml (no python3)"
  fi
fi

# -- release cleanup (module-ci.sh release): delete only a release the forge still reports as a draft.
# The publish PATCH may be applied by the forge while its reply is lost; deleting on "PUBLISHED != 1"
# alone then removes a published release. Real: log/die/jget/api/cleanup and the publish statements
# (REQ= .. PUBLISHED=1) cut from .forgejo/module-ci.sh; stubbed: curl (fake forge at https://forge.invalid).
if [ "$ASH_ONLY" != 1 ] && command -v bash >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  RW="$TUC_WORK"/release-cleanup; mkdir -p "$RW/bin"
  {
    echo 'set -euo pipefail'
    echo 'API=https://forge.invalid/api/v1/repos/example/mod RELEASE_ID=7 PUBLISHED=0 SRC_SHA=0123456789abcdef0123456789abcdef01234567'
    echo 'AUTH_DIR=$(mktemp -d) AUTH_H=$AUTH_DIR/header; : > "$AUTH_H"'
    sed -n '/^log() {/p; /^die() {/p; /^jget() {/,/^print(d)/p; /^api() {/,/^}/p; /^cleanup() {/,/^}/p' "$TUC_REPO/.forgejo/module-ci.sh"
    echo 'trap cleanup EXIT'
    echo 'if [ "$1" = publish ]; then'
    sed -n '/^REQ="\$(python3 -I -c .import json,sys;print(json.dumps({"draft":False/,/^PUBLISHED=1$/p' "$TUC_REPO/.forgejo/module-ci.sh"
    echo 'else die "upload failed"; fi'
  } > "$RW/rel.sh"
  # fake curl: logs "METHOD URL"; PATCH exits $PATCH_RC; GET of the release answers draft=$DRAFT or fails (DRAFT=fail)
  cat > "$RW/bin/curl" <<EOF
#!/bin/sh
m=GET; p=; for a in "\$@"; do [ "\$p" = -X ] && m=\$a; p=\$a; u=\$a; done
echo "\$m \$u" >> "$RW/calls"
case "\$m" in
  PATCH) exit "\${PATCH_RC:-0}" ;;
  GET) [ "\$DRAFT" = fail ] && exit 22; printf '{"id": 7, "draft": %s}' "\$DRAFT" ;;
esac
EOF
  chmod 755 "$RW/bin/curl"
  rel() { rel_mode=$1; shift; : > "$RW/calls"; env PATH="$RW/bin:$PATH" TMPDIR="$RW" "$@" bash "$RW/rel.sh" "$rel_mode" > "$RW/err" 2>&1; }
  if ! grep -q '^PUBLISHED=1$' "$RW/rel.sh" || ! grep -q '^cleanup() {' "$RW/rel.sh" || ! grep -q '^api() {' "$RW/rel.sh"; then
    ko "release cleanup: cleanup()/api()/publish statements not found in module-ci.sh"
  else
    rel publish PATCH_RC=28 DRAFT=false; rc=$?
    if [ "$rc" -ne 0 ] && grep -q '^PATCH ' "$RW/calls" && ! grep -q '^DELETE ' "$RW/calls"; then
      ok "release cleanup: failed PATCH, forge reports published: release kept, job fails"
    else ko "release cleanup: failed PATCH, published (rc=$rc): $(tr '\n' ';' < "$RW/calls")"; fi
    rel upload DRAFT=true; rc=$?
    if [ "$rc" -ne 0 ] && grep -qx 'DELETE https://forge.invalid/api/v1/repos/example/mod/releases/7' "$RW/calls"; then
      ok "release cleanup: failure before publish deletes the draft"
    else ko "release cleanup: draft not deleted (rc=$rc): $(tr '\n' ';' < "$RW/calls")"; fi
    rel publish PATCH_RC=28 DRAFT=fail; rc=$?
    if [ "$rc" -ne 0 ] && ! grep -q '^DELETE ' "$RW/calls" && grep -q 'release 7' "$RW/err"; then
      ok "release cleanup: unreadable state: nothing deleted, release id logged"
    else ko "release cleanup: unreadable state (rc=$rc): $(tr '\n' ';' < "$RW/calls")"; fi
    rel publish DRAFT=false; rc=$?
    if [ "$rc" -eq 0 ] && ! grep -q '^DELETE ' "$RW/calls"; then
      ok "release cleanup: good publish deletes nothing, exit 0"
    else ko "release cleanup: good publish (rc=$rc): $(tr '\n' ';' < "$RW/calls")"; fi
  fi
else
  skip "release cleanup (host-only: needs bash and python3)"
fi

# -- Behaviour tests --
. "$TUC_REPO/tests/lib.sh"
make_stubs
PATH="$TUC_STUBS:$PATH"
export PATH
. "$TUC_WORK/overrides.sh"

# Safety: every device tool must resolve to a stub before anything runs.
# mksh predefines alias nohup='nohup ', which looks the name up again on PATH;
# its builtin sleep is replaced by the overrides.sh function (as on every
# fake device), which calls the stub.
_safe=1
for t in mount umount nsenter chcon chown restorecon getprop getenforce pgrep pkill setsid nohup sleep cp chmod; do
  _r=$(command -v "$t")
  case "$_r" in
    "alias $t='$t '") _r=$(unalias "$t" 2>/dev/null; command -v "$t") ;;
    sleep) case "$(type sleep)" in *function*) _r="$TUC_STUBS/sleep" ;; esac ;;
  esac
  case "$_r" in
    "$TUC_STUBS/$t") ;;
    *) _safe=0; ko "stub $t does not shadow $(command -v "$t")" ;;
  esac
done

TUC_N=0
if [ "$_safe" = 1 ]; then
  for c in "$TUC_REPO"/tests/cases/*.sh; do
    . "$c"
  done
  for t in $(sed -n 's/^\(test_[a-z0-9_]*\)() *{.*/\1/p' "$TUC_REPO"/tests/cases/*.sh); do
    TUC_N=$((TUC_N + 1))
    TUC_TEST_FAILED=0
    (
      "$t"
      exit "$TUC_TEST_FAILED"
    ) >"$TUC_WORK/out.$TUC_N" 2>&1
    if [ $? -eq 0 ]; then
      ok "$t"
    else
      ko "$t"
      sed 's/^/     /' "$TUC_WORK/out.$TUC_N"
    fi
  done
fi

printf '\n%s passed, %s failed, %s skipped\n' "$PASS" "$FAILED" "$SKIP"
[ "$FAILED" -eq 0 ]
