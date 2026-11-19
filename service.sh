#!/system/bin/sh
# shellcheck shell=ash disable=SC1091,SC3043
#
# service.sh - late_start boot flow, the Live Sync watcher, and every command
# the WebUI calls. All commands print machine-readable "key=value" lines so the
# UI needs exactly one root call per refresh instead of a dozen.
#
# Usage:
#   service.sh                      boot flow (called by Magisk/KSU/APatch)
#   service.sh --status             one-shot status dump
#   service.sh --certs              user/custom certificates, base64 encoded
#   service.sh --log [lines]        tail of the service log
#   service.sh --clear-log
#   service.sh --force-inject
#   service.sh --sync               (alias: --live-sync-trigger)
#   service.sh --watch              run the watcher in the foreground
#   service.sh --watch-start        spawn the watcher detached
#   service.sh --watch-stop
#   service.sh --config KEY VALUE   LIVE_SYNC=0|1, LOG_LEVEL=0|1|2
#   service.sh --reset-fail

MODDIR="${0%/*}"
case "$MODDIR" in
  '' | "$0") MODDIR="/data/adb/modules/trust-user-certs" ;;
esac

. "$MODDIR/sh/common.sh"
. "$MODDIR/sh/inject.sh"

mkdir -p "$DATA_DIR" "$LOG_DIR" "$LOCK_DIR" "$CUSTOM_CERT_DIR" 2>/dev/null
_load_log_level

# ── Watcher process helpers ───────────────────────────────────────────────────
# The watcher is either the boot-time service.sh itself or a detached
# `service.sh --watch`; both command lines contain this path. Anything else
# holding a PID from watcher.pid (a recycled PID after a reboot, another
# module's service.sh) is not ours and is never signalled.
WATCHER_ID="$MODULE_ID/service.sh"
TAB=$(printf '\t')

watcher_pid() { read_pid_file "$WATCH_PID_FILE"; }

watcher_is_running() { pid_is "$(watcher_pid)" "$WATCHER_ID"; }

# inotifyd_is <pid> - our inotifyd: its argv holds the watched parent dir.
inotifyd_is() { pid_is "$1" "inotifyd" && pid_is "$1" "$USER_CERT_PARENT"; }

# Runtime files are never trusted across a boot.
watcher_clear_runtime() {
  rm -f "$WATCH_PID_FILE" "$INOTIFYD_PID_FILE" "$WATCH_FIFO" "$WATCH_ERR_FILE" 2>/dev/null
}

watcher_shutdown() {
  trap '' TERM INT HUP
  ev_stop_inotifyd
  [ "${POLL_SLEEP_PID:-0}" -gt 0 ] && kill "$POLL_SLEEP_PID" 2>/dev/null
  exec 3>&-
  rm -f "$WATCH_FIFO" 2>/dev/null
  [ "$(watcher_pid)" = "$$" ] && rm -f "$WATCH_PID_FILE" 2>/dev/null
  write_stats "LIVESYNC_STATUS=stopped" "LIVESYNC_PID=0"
  log_info "Watcher stopped (pid $$)"
  exit 0
}

# ── Event engine: busybox inotifyd -> FIFO on fd 3 -> builtin read ────────────
# Idle cost is one sleeping inotifyd and one shell blocked in read(2); nothing
# is spawned until an event arrives or the WATCH_TICK health check runs.
EV_PID=0
POLL_SLEEP_PID=0

ev_stop_inotifyd() {
  if [ "$EV_PID" -gt 0 ] && inotifyd_is "$EV_PID"; then
    kill "$EV_PID" 2>/dev/null
  fi
  EV_PID=0
  rm -f "$INOTIFYD_PID_FILE" 2>/dev/null
}

# ev_start_inotifyd - (re)start inotifyd on every target that exists right
# now. The parent is always watched, so a cacerts-added that does not exist
# yet (no user certificate installed ever) is picked up when Android creates it.
ev_start_inotifyd() {
  ev_stop_inotifyd
  set -- "$USER_CERT_PARENT:$WATCH_PARENT_MASK"
  [ -d "$USER_CERT_DIR" ] && set -- "$@" "$USER_CERT_DIR:$WATCH_MASK"
  [ -d "$CUSTOM_CERT_DIR" ] && set -- "$@" "$CUSTOM_CERT_DIR:$WATCH_MASK"
  "$BUSYBOX" inotifyd - "$@" >&3 2>"$WATCH_ERR_FILE" &
  EV_PID=$!
  echo "$EV_PID" >"$INOTIFYD_PID_FILE"
  # A bad path makes inotifyd exit at once; a real check beats any guess.
  sleep 1
  if pid_alive "$EV_PID"; then
    log_debug "inotifyd pid $EV_PID watching: $*"
    return 0
  fi
  log_warn "inotifyd exited at start: $(head -n 2 "$WATCH_ERR_FILE" 2>/dev/null | tr '\n' ' ')"
  EV_PID=0
  rm -f "$INOTIFYD_PID_FILE" 2>/dev/null
  return 1
}

ev_setup() {
  if [ -z "$BUSYBOX" ] || ! has_applet inotifyd; then
    log_warn "busybox inotifyd is unavailable - Live Sync will poll every ${POLL_INTERVAL}s"
    return 1
  fi
  rm -f "$WATCH_FIFO" 2>/dev/null
  $CMD_MKFIFO "$WATCH_FIFO" 2>/dev/null
  if [ ! -p "$WATCH_FIFO" ]; then
    log_warn "Cannot create $WATCH_FIFO - Live Sync will poll every ${POLL_INTERVAL}s"
    return 1
  fi
  # Read-write open: never blocks, never hits EOF when inotifyd restarts.
  exec 3<>"$WATCH_FIFO"
  if ! ev_start_inotifyd; then
    exec 3>&-
    rm -f "$WATCH_FIFO" 2>/dev/null
    log_warn "inotifyd does not run here - Live Sync will poll every ${POLL_INTERVAL}s"
    return 1
  fi
  return 0
}

# ev_loop - only returns when event mode has to be given up (poll takes over).
ev_loop() {
  _pending=0 # a sync is owed
  _rearm=0   # the set of watch targets changed, restart inotifyd first
  _first=0   # uptime of the first event of the current burst
  _what=""
  _nev=0
  _restarts=0
  _fast=0
  uptime_s
  _win=$UPTIME_S

  while :; do
    if [ "$_pending" = 1 ]; then _t=$WATCH_DEBOUNCE; else _t=$WATCH_TICK; fi
    uptime_s
    _t0=$UPTIME_S

    # read -t: supported by busybox ash and mksh, the only shells used here.
    # shellcheck disable=SC3045
    if IFS="$TAB" read -r -t "$_t" _ev _dir _name <&3; then
      _fast=0
      _hit=0
      case "$_ev" in
        *o*) _hit=1 ;; # kernel queue overflow: events were lost, resync
      esac
      case "$_dir" in
        "$USER_CERT_PARENT")
          if [ "$_name" = "${USER_CERT_DIR##*/}" ]; then
            _hit=1
            _rearm=1
          fi
          ;;
        "$USER_CERT_DIR" | "$CUSTOM_CERT_DIR")
          _hit=1
          case "$_ev" in *[DMx]*) _rearm=1 ;; esac
          ;;
      esac
      uptime_s
      if [ "$_hit" = 1 ]; then
        _nev=$((_nev + 1))
        if [ "$_pending" = 0 ]; then
          _pending=1
          # The burst starts when its first event ARRIVES - not when this
          # read began (after a 60 s idle wait that would count as "late"
          # and split every burst in two, as seen on the phone).
          _first=$UPTIME_S
          _what="$_ev ${_dir##*/}/${_name}"
        fi
      fi
      [ "$_pending" = 1 ] || continue
      # Keep collecting the burst, but never postpone a sync forever.
      [ $((UPTIME_S - _first)) -ge "$WATCH_MAX_DELAY" ] || continue
    else
      # read failed: a timeout, or something is badly wrong with fd 3.
      uptime_s
      if [ "$UPTIME_S" -le "$_t0" ] && [ "$_t" -ge 1 ]; then
        _fast=$((_fast + 1))
        if [ "$_fast" -gt 20 ]; then
          log_error "Event pipe is not readable - giving up event mode"
          return 1
        fi
      else
        _fast=0
      fi
    fi

    if [ "$_rearm" = 1 ]; then
      _rearm=0
      log_info "Watch targets changed - restarting inotifyd"
      ev_start_inotifyd
    fi

    if [ "$_pending" = 1 ]; then
      _pending=0
      log_info "Change detected ($_nev event(s), first: $_what)"
      _nev=0
      do_live_sync
      log_rotate
    fi

    # Health check. An inotifyd that dies silently would turn Live Sync off
    # without anyone noticing - exactly the v3.1 inotifywait failure.
    if ! pid_alive "$EV_PID"; then
      uptime_s
      if [ $((UPTIME_S - _win)) -gt "$WATCH_RESTART_WINDOW" ]; then
        _win=$UPTIME_S
        _restarts=0
      fi
      _restarts=$((_restarts + 1))
      write_stats "WATCH_RESTARTS=$_restarts"
      if [ "$_restarts" -gt "$WATCH_RESTART_MAX" ]; then
        log_warn "inotifyd failed $_restarts times within ${WATCH_RESTART_WINDOW}s - switching to poll mode"
        return 1
      fi
      if [ "$EV_PID" -gt 0 ]; then
        log_warn "inotifyd (pid $EV_PID) is gone - restarting ($_restarts/$WATCH_RESTART_MAX)"
      else
        log_warn "inotifyd is not running - retrying ($_restarts/$WATCH_RESTART_MAX)"
      fi
      if ev_start_inotifyd; then
        # Changes made while it was down were not seen: resync once.
        _pending=1
        _first=$UPTIME_S
        _what="watcher restart"
      fi
    fi
  done
}

# ── Poll engine (fallback) ────────────────────────────────────────────────────
# Directory mtimes change on create/delete/rename; file mtimes and sizes catch
# an in-place overwrite (cp -f into the custom dir).
poll_fingerprint() {
  if [ -n "$CMD_STAT" ]; then
    $CMD_STAT -c '%n %Y %s' "$USER_CERT_DIR" "$USER_CERT_DIR"/* \
      "$CUSTOM_CERT_DIR" "$CUSTOM_CERT_DIR"/* 2>/dev/null
  else
    ls -la "$USER_CERT_DIR" "$CUSTOM_CERT_DIR" 2>/dev/null
  fi
}

poll_loop() {
  write_stats "LIVESYNC_MODE=poll" "LIVESYNC_PID=$$" "LIVESYNC_STATUS=running"
  log_info "Polling the certificate store every ${POLL_INTERVAL}s"
  _last=$(poll_fingerprint)
  while :; do
    # sleep & wait: a TERM arrives while waiting and the trap runs at once.
    sleep "$POLL_INTERVAL" &
    POLL_SLEEP_PID=$!
    wait "$POLL_SLEEP_PID"
    POLL_SLEEP_PID=0
    _cur=$(poll_fingerprint)
    if [ "$_cur" != "$_last" ]; then
      log_info "Poll: change detected in the certificate store"
      do_live_sync
      log_rotate
    fi
    # The fingerprint from before the sync: a change made while it ran
    # differs from it and is synced at the next poll.
    _last=$_cur
  done
}

# ── The watcher itself ────────────────────────────────────────────────────────
run_watcher() {
  if watcher_is_running && [ "$(watcher_pid)" != "$$" ]; then
    log_warn "Watcher already running (pid $(watcher_pid)) - not starting a second one"
    return 0
  fi

  daemon_detach
  # Traps first, PID file second: a stop request can never find a PID whose
  # owner would ignore it.
  trap 'watcher_shutdown' TERM INT HUP
  echo "$$" >"$WATCH_PID_FILE"

  # Never inherit a lock from a process that died mid-sync.
  lock_is_held "$SYNC_LOCK" || lock_release "$SYNC_LOCK"

  if ev_setup; then
    # No CHLD trap on purpose: in busybox ash a CHLD trap that fires while
    # another trap runs (the TERM shutdown) makes every && / if in it read
    # false. A dead inotifyd is found by the WATCH_TICK health check instead.
    log_sep "Live Sync watcher started (mode=events, pid=$$)"
    write_stats "LIVESYNC_MODE=events" "LIVESYNC_PID=$$" "LIVESYNC_STATUS=running" "WATCH_RESTARTS=0"
    ev_loop
    ev_stop_inotifyd
    exec 3>&-
    rm -f "$WATCH_FIFO" 2>/dev/null
  else
    log_sep "Live Sync watcher started (mode=poll, pid=$$)"
  fi
  poll_loop
}

cmd_watch_start() {
  if watcher_is_running; then
    log_debug "Watcher already running (pid $(watcher_pid))"
    echo "watcher=already-running"
    echo "rc=0"
    return 0
  fi
  # Always the same shell as at boot (busybox ash), not the caller's mksh.
  if [ -n "$BUSYBOX" ]; then
    spawn_detached "$BUSYBOX" sh "$MODDIR/service.sh" --watch
  else
    spawn_detached sh "$MODDIR/service.sh" --watch
  fi
  _i=0
  while [ "$_i" -lt 5 ]; do
    sleep 1
    if watcher_is_running; then
      echo "watcher=started"
      echo "rc=0"
      unset _i
      return 0
    fi
    _i=$((_i + 1))
  done
  log_error "Watcher failed to start"
  echo "watcher=failed"
  echo "rc=1"
  unset _i
  return 1
}

cmd_watch_stop() {
  _p=$(watcher_pid)
  if pid_is "$_p" "$WATCHER_ID"; then
    kill "$_p" 2>/dev/null
    # The watcher's TERM trap exits within a fraction of a second; poll in
    # 0.2 s steps (1 s where sleep has no fractions), give up after ~4 s.
    _i=0
    while pid_alive "$_p" && [ "$_i" -lt 20 ]; do
      sleep 0.2 2>/dev/null || sleep 1
      _i=$((_i + 1))
    done
    if pid_alive "$_p"; then
      kill -9 "$_p" 2>/dev/null
      kill_children "$_p" KILL
      log_warn "Watcher (pid $_p) ignored TERM - killed"
    fi
  fi
  # An inotifyd orphaned by a hard kill.
  _ip=$(read_pid_file "$INOTIFYD_PID_FILE")
  inotifyd_is "$_ip" && kill "$_ip" 2>/dev/null
  watcher_clear_runtime
  write_stats "LIVESYNC_STATUS=stopped" "LIVESYNC_PID=0"
  echo "watcher=stopped"
  echo "rc=0"
  unset _p _i _ip
  return 0
}

# ── UI commands ───────────────────────────────────────────────────────────────
cmd_force_inject() {
  log_sep "Force inject (from UI)"
  # Serialised with Live Sync: both rebuild the stage, and one run's pass that
  # removes unstaged certs from the store would hit the other's half-built one.
  if ! lock_acquire "$SYNC_LOCK" 20; then
    log_error "Force inject skipped - a sync is still running"
    echo "rc=1"
    return 1
  fi
  _store=$(trust_store_dir)
  if is_mounted "$_store"; then
    sync_store
    _rc=$?
    if [ "$_rc" -ne 0 ]; then
      log_warn "Refresh failed verification - rebuilding the overlay from scratch"
      inject_full
      _rc=$?
    fi
  else
    inject_full
    _rc=$?
  fi
  lock_release "$SYNC_LOCK"
  if [ "$_rc" -eq 0 ]; then
    write_fail_count 0 || log_warn "Boot fail counter could not be reset"
    rm -f "$BLOCK_MARKER" 2>/dev/null
    write_stats "BLOCKED=0"
    log_info "Force inject complete"
  else
    log_error "Force inject failed"
  fi
  echo "rc=$_rc"
  return $_rc
}

cmd_sync() {
  log_sep "Manual sync (from UI)"
  do_live_sync
  _rc=$?

  # Live Sync is meant to be on but the watcher is gone - most likely it was
  # started from the WebUI and died with the manager app. Bring it back.
  if [ "$(read_cfg LIVE_SYNC)" = "1" ] && ! watcher_is_running; then
    log_warn "Watcher was not running - starting it"
    cmd_watch_start >/dev/null
    if watcher_is_running; then
      echo "watcher=restarted"
    else
      echo "watcher=failed"
    fi
  fi

  echo "rc=$_rc"
  return $_rc
}

cmd_reset_fail() {
  if ! write_fail_count 0; then
    log_error "Boot fail counter could not be reset from the UI (still $(read_fail_count))"
    echo "rc=1"
    return 1
  fi
  rm -f "$BLOCK_MARKER" 2>/dev/null
  write_stats "BLOCKED=0"
  if guard_blocked; then
    log_error "Boot fail counter reset, but the bootloop guard is still active (marker or BLOCKED stat could not be cleared)"
    echo "rc=1"
    return 1
  fi
  log_info "Boot fail counter reset from the UI"
  echo "rc=0"
}

cmd_config() {
  case "$1" in
    LIVE_SYNC)
      case "$2" in
        0 | 1) ;;
        *)
          echo "rc=1"
          return 1
          ;;
      esac
      ;;
    LOG_LEVEL)
      case "$2" in
        0 | 1 | 2) ;;
        *)
          echo "rc=1"
          return 1
          ;;
      esac
      ;;
    *)
      echo "rc=1"
      return 1
      ;;
  esac

  write_cfg "$1" "$2" || {
    echo "rc=1"
    return 1
  }
  _load_log_level
  # A log level change is always written, also when the new level is 0, so
  # the WebUI log shows it at once.
  if [ "$1" = LOG_LEVEL ]; then _log INFO "Config: $1=$2"; else log_info "Config: $1=$2"; fi

  if [ "$1" = "LIVE_SYNC" ]; then
    if [ "$2" = "1" ]; then
      cmd_watch_start
      return $?
    else
      cmd_watch_stop
      return $?
    fi
  fi
  echo "rc=0"
  return 0
}

# cert_is_excluded <file> <store> - dropped by a rule: missing from the stage
# when there is one, else (a failed sync removed it) not in the store and
# matched by the rules themselves.
cert_is_excluded() {
  if [ -d "$CERT_STAGE" ]; then
    [ ! -f "$CERT_STAGE/${1##*/}" ]
  else
    [ ! -f "$2/${1##*/}" ] && cert_excluded "$1"
  fi
}

cmd_status() {
  _store=$(trust_store_dir)

  _users=0
  _trusted=0
  _excluded=0
  _badname=0
  if [ -d "$USER_CERT_DIR" ]; then
    for _f in "$USER_CERT_DIR"/*; do
      [ -f "$_f" ] || continue
      _users=$((_users + 1))
      if cert_is_excluded "$_f" "$_store"; then
        _excluded=$((_excluded + 1))
        continue
      fi
      [ -f "$_store/${_f##*/}" ] || continue
      # In the store under a name Android never looks up: not trusted.
      if cert_name_ok "$_f"; then
        _trusted=$((_trusted + 1))
      else
        _badname=$((_badname + 1))
      fi
    done
  fi

  _cust=0
  _ctrusted=0
  _cexcluded=0
  _cbadname=0
  if [ -d "$CUSTOM_CERT_DIR" ]; then
    for _f in "$CUSTOM_CERT_DIR"/*; do
      [ -f "$_f" ] || continue
      _cust=$((_cust + 1))
      if cert_is_excluded "$_f" "$_store"; then
        _cexcluded=$((_cexcluded + 1))
        continue
      fi
      [ -f "$_store/${_f##*/}" ] || continue
      if cert_name_ok "$_f"; then
        _ctrusted=$((_ctrusted + 1))
      else
        _cbadname=$((_cbadname + 1))
      fi
    done
  fi

  if watcher_is_running; then
    _wstate="running"
  elif [ "$(read_cfg LIVE_SYNC)" = "1" ]; then
    _wstate="dead"
  else
    _wstate="disabled"
  fi

  printf 'SDK=%s\n' "$SDK"
  printf 'VERSION=%s\n' "$(sed -n 's/^version=//p' "$MODDIR/module.prop" 2>/dev/null | head -n 1)"
  printf 'STORE_DIR=%s\n' "$_store"
  printf 'MOUNTED=%s\n' "$(is_mounted "$_store" && echo 1 || echo 0)"
  printf 'STORE_CERTS=%s\n' "$(count_files "$_store")"
  printf 'BASE_CERTS=%s\n' "$(count_files "$BASE_CERT_DIR")"
  printf 'STAGE_CERTS=%s\n' "$(count_files "$CERT_STAGE")"
  printf 'USER_CERTS=%s\n' "$_users"
  printf 'USER_TRUSTED=%s\n' "$_trusted"
  printf 'USER_EXCLUDED=%s\n' "$_excluded"
  printf 'USER_BADNAME=%s\n' "$_badname"
  printf 'CUSTOM_CERTS=%s\n' "$_cust"
  printf 'CUSTOM_TRUSTED=%s\n' "$_ctrusted"
  printf 'CUSTOM_EXCLUDED=%s\n' "$_cexcluded"
  printf 'CUSTOM_BADNAME=%s\n' "$_cbadname"
  printf 'CUSTOM_DIR=%s\n' "$CUSTOM_CERT_DIR"
  printf 'FAIL=%s\n' "$(read_fail_count)"
  printf 'FAIL_LIMIT=%s\n' "$FAIL_LIMIT"
  printf 'BLOCKED=%s\n' "$(guard_blocked && echo 1 || echo 0)"
  printf 'INJECT_OK=%s\n' "$(read_stat INJECT_OK)"
  printf 'LAST_INJECT=%s\n' "$(read_stat LAST_INJECT)"
  printf 'LIVE_SYNC=%s\n' "$(read_cfg LIVE_SYNC)"
  printf 'LOG_LEVEL=%s\n' "$(read_cfg LOG_LEVEL)"
  printf 'WATCHER=%s\n' "$_wstate"
  printf 'WATCHER_PID=%s\n' "$(watcher_pid)"
  printf 'WATCH_MODE=%s\n' "$(read_stat LIVESYNC_MODE)"
  _ip=$(read_pid_file "$INOTIFYD_PID_FILE")
  inotifyd_is "$_ip" || _ip=0
  printf 'INOTIFYD_PID=%s\n' "$_ip"
  printf 'WATCH_RESTARTS=%s\n' "$(read_stat WATCH_RESTARTS)"
  if [ -n "$BUSYBOX" ] && has_applet inotifyd; then _ia=1; else _ia=0; fi
  printf 'INOTIFYD=%s\n' "$_ia"
  printf 'LIVESYNCS=%s\n' "$(read_stat LIVESYNCS)"
  printf 'LAST_SYNC=%s\n' "$(read_stat LAST_SYNC)"
  printf 'LOG_SIZE=%s\n' "$(file_size "$LOG_FILE")"
  printf 'ENFORCING=%s\n' "$(getenforce 2>/dev/null)"
  printf 'BUSYBOX=%s\n' "${BUSYBOX:-none}"
  printf 'TOOL_NSENTER=%s\n' "${CMD_NSENTER:-none}"
  printf 'TOOL_PGREP=%s\n' "${CMD_PGREP:-none}"
  printf 'TOOL_SETSID=%s\n' "${CMD_SETSID:-none}"
  printf 'NOW=%s\n' "$(date +%s)"
  printf 'rc=0\n'
  unset _store _users _trusted _excluded _badname _wstate _f _ip _ia _cust _ctrusted _cexcluded _cbadname
}

# Emits: <name>|<source>|<trusted 0/1/x>|<base64 of the file (PEM or DER)>
# At most CERTS_MAX per source; the rest is reported as "+more|<source>|<n>".
CERTS_MAX=40
cmd_certs() {
  _store=$(trust_store_dir)
  for _dir in "$USER_CERT_DIR" "$CUSTOM_CERT_DIR"; do
    [ -d "$_dir" ] || continue
    if [ "$_dir" = "$USER_CERT_DIR" ]; then _src="user"; else _src="custom"; fi
    _n=0
    for _f in "$_dir"/*; do
      [ -f "$_f" ] || continue
      _n=$((_n + 1))
      [ "$_n" -gt "$CERTS_MAX" ] && continue
      _base="${_f##*/}"
      if [ -f "$_store/$_base" ]; then
        _t=1
      elif cert_is_excluded "$_f" "$_store"; then
        _t=x
      else
        _t=0
      fi
      printf '%s|%s|%s|%s\n' "$_base" "$_src" "$_t" "$(${CMD_BASE64:-base64} "$_f" 2>/dev/null | tr -d '\n')"
    done
    [ "$_n" -gt "$CERTS_MAX" ] && printf '+more|%s|%s\n' "$_src" "$((_n - CERTS_MAX))"
  done
  unset _store _n _dir _src _f _base _t
}

# Prints the command the WebUI should pipe through to base64-encode output.
# Single line on purpose: the legacy ksu.exec bridge only returns the last one.
cmd_b64cmd() {
  if [ -n "$CMD_BASE64" ]; then
    printf '%s\n' "$CMD_BASE64"
  else
    printf 'base64\n'
  fi
}

cmd_log() {
  _lines="${1:-400}"
  case "$_lines" in
    '' | *[!0-9]*) _lines=400 ;;
  esac
  tail -n "$_lines" "$LOG_FILE" 2>/dev/null
  unset _lines
}

cmd_clear_log() {
  printf '' >"$LOG_FILE" 2>/dev/null
  log_info "Log cleared from the UI"
  echo "rc=0"
}

# ── Boot flow ─────────────────────────────────────────────────────────────────
boot_flow() {
  log_rotate
  log_sep "service.sh boot (SDK $SDK)"
  log_tools
  # PIDs from the previous boot mean nothing now (and may belong to anything).
  watcher_clear_runtime
  repair_user_cert_dir
  write_stats "BOOT_STAGE=service"

  if _z=$(wait_for_zygote 60); then
    log_info "Zygote ready after ${_z}s"
  else
    log_warn "Zygote not seen after ${_z}s - continuing"
  fi

  # Android >= 14: the injection deferred by post-fs-data.sh happens here.
  # This block MUST run before the LIVE_SYNC check below - in v2 the early
  # `exit 0` for a disabled Live Sync also skipped the injection entirely.
  if [ "$SDK" -ge 34 ]; then
    if guard_blocked; then
      log_error "Deferred inject skipped - bootloop guard is active"
    else
      # Serialised with a sync or Force Inject started meanwhile (a root CLI
      # call). Never skipped for the lock: still held after the wait, the
      # inject runs without it.
      _bl=0
      if lock_acquire "$SYNC_LOCK" 20; then
        _bl=1
      else
        log_warn "Sync lock still held after 20 s - deferred inject runs without it"
      fi
      if inject_high; then
        log_info "Deferred inject complete"
      else
        log_error "Deferred inject failed"
      fi
      [ "$_bl" = 1 ] && [ "$(read_pid_file "$SYNC_LOCK/pid")" = "$$" ] && lock_release "$SYNC_LOCK"
    fi
    del_stat DEFERRED
  fi

  # Reaching late_start with a booted system is the only honest signal that the
  # current injection did not put the device into a bootloop. A boot that the
  # guard blocked injected nothing, so it proves nothing: the counter stays
  # until it is reset by hand.
  if wait_for_prop sys.boot_completed 1 180; then
    sleep "$SETTLE_SECONDS"
    if guard_blocked; then
      log_warn "Boot completed with the bootloop guard active - fail counter left at $(read_fail_count) until it is reset"
    elif write_fail_count 0; then
      log_info "Boot completed - fail counter reset"
    else
      log_warn "Boot completed, but the fail counter could not be reset (still $(read_fail_count))"
    fi
  else
    log_warn "sys.boot_completed never turned 1 - fail counter left at $(read_fail_count)"
  fi

  if [ "$(read_cfg LIVE_SYNC)" = "1" ]; then
    run_watcher
  else
    log_info "Live Sync is disabled - watcher not started"
    write_stats "LIVESYNC_STATUS=disabled" "LIVESYNC_PID=0"
  fi
}

# ── Dispatch ──────────────────────────────────────────────────────────────────
case "$1" in
  --status) cmd_status ;;
  --certs) cmd_certs ;;
  --log) cmd_log "$2" ;;
  --b64cmd) cmd_b64cmd ;;
  --clear-log) cmd_clear_log ;;
  --force-inject) cmd_force_inject ;;
  --sync | --live-sync-trigger) cmd_sync ;;
  --watch) run_watcher ;;
  --watch-start) cmd_watch_start ;;
  --watch-stop) cmd_watch_stop ;;
  --config) cmd_config "$2" "$3" ;;
  --reset-fail) cmd_reset_fail ;;
  '') boot_flow ;;
  *)
    echo "unknown command: $1"
    echo "rc=1"
    exit 1
    ;;
esac
