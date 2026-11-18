#!/system/bin/sh
# uninstall.sh - runs when the module is removed via Magisk/KSU/APatch. The
# root manager does that at the next boot, early (post-fs-data stage), before
# zygote and apps start; the module's own boot scripts no longer run then.

DATA_DIR="/data/adb/trust-user-certs"

# Stop the Live Sync watcher and its inotifyd - but only processes that really
# are ours: a PID file can point at a recycled PID. Self-contained on purpose
# (the module files may already be gone when this runs).
tuc_pid() {
  _p=$(cat "$1" 2>/dev/null)
  case "$_p" in '' | *[!0-9]*) _p=0 ;; esac
  printf '%s' "$_p"
}
tuc_is() { [ "$1" -gt 0 ] && [ -r "/proc/$1/cmdline" ] && grep -q -F -- "$2" "/proc/$1/cmdline" 2>/dev/null; }

PID=$(tuc_pid "$DATA_DIR/watcher.pid")
if tuc_is "$PID" "trust-user-certs/service.sh"; then
  kill "$PID" 2>/dev/null
  sleep 1
  tuc_is "$PID" "trust-user-certs/service.sh" && kill -9 "$PID" 2>/dev/null
fi
PID=$(tuc_pid "$DATA_DIR/inotifyd.pid")
if tuc_is "$PID" "inotifyd" && tuc_is "$PID" "/data/misc/user/0"; then
  kill "$PID" 2>/dev/null
fi

# Cleanup only, not a live revert: at the boot that removes the module nothing
# has mounted the overlay. Kept for a manager that runs this script at once.
umount /apex/com.android.conscrypt/cacerts 2>/dev/null
umount /system/etc/security/cacerts 2>/dev/null

rm -rf "$DATA_DIR"
rm -rf /data/local/tmp/cert
rm -rf /mnt/tuc_instaler /mnt/tuc_stage
