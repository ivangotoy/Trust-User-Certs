#!/system/bin/sh
# shellcheck shell=ash disable=SC3043
#
# inject.sh - certificate staging and trust-store injection.
# Requires sh/common.sh to be sourced first.

# sizes_match <dst> <src>... - true if every regular file of the sources is in
# <dst> with the size it has in the last source holding that name (a later
# source overrides an earlier one, as the copies do). Prints the first name
# that is missing or has another size. A full /data or tmpfs can leave a file
# out, empty or cut part way. One wc per directory and one awk in all.
sizes_match() {
  _sm_dst="$1"
  shift
  {
    for _sm_d in "$@"; do wc -c "$_sm_d"/* 2>/dev/null; done
    echo '--'
    wc -c "$_sm_dst"/* 2>/dev/null
  } | ${CMD_AWK:-awk} '
    $0 == "--" { dst = 1; next }
    {
      s = $1; p = $0
      sub(/^[ \t]*[0-9]+[ \t]+/, "", p)
      if (index(p, "/") == 0) next
      n = p; sub(/.*\//, "", n)
      if (dst) D[n] = s; else W[n] = s
    }
    END {
      for (n in W) if (!(n in D) || D[n] != W[n]) { print n; exit 1 }
    }'
  _sm_rc=$?
  unset _sm_dst _sm_d
  return "$_sm_rc"
}

# ── Pristine snapshot of the OS trust store ───────────────────────────────────
# Taken only while our own overlay is NOT active, so re-staging never feeds our
# merged set back into itself. This is what makes cert *removal* propagate:
# the stage is rebuilt from the pristine base every time.
refresh_base_certs() {
  _rb_live=$(trust_store_dir)

  if is_mounted "$_rb_live"; then
    log_debug "Trust store already overlaid - keeping cached base snapshot"
    unset _rb_live
    return 0
  fi

  mkdir -p "$BASE_CERT_DIR" 2>/dev/null
  if dir_has_files "$_rb_live"; then
    rm -f "$BASE_CERT_DIR"/* 2>/dev/null
    cp -f "$_rb_live"/* "$BASE_CERT_DIR"/ 2>/dev/null
    # Every file must have arrived whole.
    if ! _rb_bad=$(sizes_match "$BASE_CERT_DIR" "$_rb_live"); then
      log_error "Base snapshot incomplete: $_rb_bad not copied whole from $_rb_live (is /data full?)"
      unset _rb_live _rb_bad
      return 1
    fi
    log_debug "Base snapshot refreshed: $(count_files "$BASE_CERT_DIR") certs from $_rb_live"
    unset _rb_bad
  else
    log_warn "Live trust store $_rb_live is empty - snapshot not refreshed"
  fi
  unset _rb_live
  return 0
}

# cert_has <pattern> <file> - the pattern (grep basic regex) is searched in
# the certificate itself. A PEM file is base64 text, so a subject name never
# appears in it literally: its body is decoded and searched as DER too.
cert_has() {
  grep -q -- "$1" "$2" 2>/dev/null && return 0
  [ -n "$CMD_BASE64" ] || return 1
  grep -q -- '-----BEGIN' "$2" 2>/dev/null || return 1
  sed -n '/-----BEGIN/,/-----END/p' "$2" 2>/dev/null | grep -v -- '-----' | tr -d '\r' |
    $CMD_BASE64 -d 2>/dev/null | grep -q -- "$1"
}

# ── Exclusion rules (AdGuard & friends) ───────────────────────────────────────
# Hash rules match <hash>.* in the stage. Subject rules are matched only against
# certificates that came from the user/custom stores - scanning all ~150 system
# certs on every sync was pure overhead.
remove_conflicting_certs() {
  _rc_dir="$1"

  if [ -f "$EXCLUDE_HASH_FILE" ]; then
    while IFS= read -r _rc_hash; do
      _rc_hash="${_rc_hash%"$CR"}" # a rules file saved on Windows
      case "$_rc_hash" in
        '' | '#'*) continue ;;
      esac
      # A rule is a subject hash, never a path: anything else is skipped.
      case "$_rc_hash" in
        [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
        *)
          log_warn "exclude_hashes: '$_rc_hash' is not an 8-digit lowercase hex hash - ignored"
          continue
          ;;
      esac
      if [ -f "$_rc_dir/$_rc_hash.0" ] || [ -n "$(ls "$_rc_dir/$_rc_hash".* 2>/dev/null)" ]; then
        rm -f "$_rc_dir/$_rc_hash".* 2>/dev/null
        log_debug "Excluded by hash: $_rc_hash"
      fi
    done <"$EXCLUDE_HASH_FILE"
  fi

  [ -f "$EXCLUDE_SUBJ_FILE" ] || {
    unset _rc_dir _rc_hash
    return 0
  }
  [ -s "$EXCLUDE_SUBJ_FILE" ] || {
    unset _rc_dir _rc_hash
    return 0
  }

  for _rc_src in "$USER_CERT_DIR" "$CUSTOM_CERT_DIR"; do
    [ -d "$_rc_src" ] || continue
    for _rc_f in "$_rc_src"/*; do
      [ -f "$_rc_f" ] || continue
      _rc_base="${_rc_f##*/}"
      [ -f "$_rc_dir/$_rc_base" ] || continue
      while IFS= read -r _rc_pat; do
        _rc_pat="${_rc_pat%"$CR"}"
        case "$_rc_pat" in
          '' | '#'*) continue ;;
        esac
        if cert_has "$_rc_pat" "$_rc_f"; then
          rm -f "$_rc_dir/$_rc_base" 2>/dev/null
          log_debug "Excluded by subject '$_rc_pat': $_rc_base"
          break
        fi
      done <"$EXCLUDE_SUBJ_FILE"
    done
  done

  unset _rc_dir _rc_hash _rc_src _rc_f _rc_base _rc_pat
  return 0
}

# ── Custom certs ──────────────────────────────────────────────────────────────
# Copied into the stage ONLY. The pre-v3 code also wrote them into
# $USER_CERT_DIR, which re-triggered the inotify watcher on every inject.
copy_custom_certs() {
  _cc_dst="$1"
  [ -d "$CUSTOM_CERT_DIR" ] || return 0
  dir_has_files "$CUSTOM_CERT_DIR" || return 0

  for _cc_f in "$CUSTOM_CERT_DIR"/*; do
    [ -f "$_cc_f" ] || continue
    _cc_base="${_cc_f##*/}"
    if ! cert_name_ok "$_cc_f"; then
      _cc_hash=$(cert_name_hash "$_cc_f")
      if [ -n "$_cc_hash" ]; then
        log_warn "Custom cert '$_cc_base' has the wrong file name - Android ignores it, rename it to $_cc_hash.0"
      else
        log_warn "Custom cert '$_cc_base' is not named <subject_hash_old>.0 - Android ignores it"
      fi
    fi
    cp -f "$_cc_f" "$_cc_dst"/ 2>/dev/null
  done

  log_debug "Custom certs staged from $CUSTOM_CERT_DIR"
  unset _cc_dst _cc_f _cc_base _cc_hash
  return 0
}

# ── Build the full certificate set ────────────────────────────────────────────
# Returns 1 if any copy came up short (a full /data, say). The callers then
# leave the trust store alone: sync_store deletes whatever is not staged, and
# a mount of a short stage would hide the stock certificates from every app.
stage_certs() {
  refresh_base_certs || return 1

  mkdir -p "$CERT_STAGE" 2>/dev/null
  rm -f "$CERT_STAGE"/* 2>/dev/null

  cp -f "$BASE_CERT_DIR"/* "$CERT_STAGE"/ 2>/dev/null
  _sc_src="$BASE_CERT_DIR"

  if ! dir_has_files "$CERT_STAGE"; then
    log_warn "Base snapshot empty - falling back to the live store"
    _sc_src=$(trust_store_dir)
    cp -f "$_sc_src"/* "$CERT_STAGE"/ 2>/dev/null
  fi

  if dir_has_files "$USER_CERT_DIR"; then
    cp -f "$USER_CERT_DIR"/* "$CERT_STAGE"/ 2>/dev/null
    log_debug "User certs staged: $(count_files "$USER_CERT_DIR")"
  else
    log_debug "No user certificates present"
  fi

  copy_custom_certs "$CERT_STAGE"

  # Checked before the exclusion rules, which may drop any of these on purpose.
  # A failed stage is removed: --status and --certs would read its gaps as
  # certificates excluded by a rule.
  if ! dir_has_files "$CERT_STAGE"; then
    log_error "Staging failed: no certificates staged"
    rm -rf "$CERT_STAGE" 2>/dev/null
    unset _sc_src
    return 1
  fi
  if ! _sc_bad=$(sizes_match "$CERT_STAGE" "$_sc_src" "$USER_CERT_DIR" "$CUSTOM_CERT_DIR"); then
    log_error "Staging failed: $_sc_bad was not copied whole (is /data full?)"
    rm -rf "$CERT_STAGE" 2>/dev/null
    unset _sc_src _sc_bad
    return 1
  fi
  unset _sc_src _sc_bad

  remove_conflicting_certs "$CERT_STAGE"

  log_info "Staged $(count_files "$CERT_STAGE") certificates"
  return 0
}

# ── Verification ──────────────────────────────────────────────────────────────
# Every user certificate must be visible in the live store, and the store must
# not be smaller than the base system set. Without this the module used to
# report success even when every single mount had failed.
verify_inject() {
  _vi_store=$(trust_store_dir)
  _vi_want=$(count_files "$CERT_STAGE")
  _vi_have=$(count_files "$_vi_store")
  _vi_users=0
  _vi_found=0

  if [ -d "$USER_CERT_DIR" ]; then
    for _vi_f in "$USER_CERT_DIR"/*; do
      [ -f "$_vi_f" ] || continue
      # Certificates dropped by an exclusion rule are absent from the stage on
      # purpose - they must not count as a verification failure.
      [ -f "$CERT_STAGE/${_vi_f##*/}" ] || continue
      _vi_users=$((_vi_users + 1))
      [ -f "$_vi_store/${_vi_f##*/}" ] && _vi_found=$((_vi_found + 1))
    done
  fi

  # Custom certificates get the same check. Before v4 they were not verified
  # at all, so one that never reached the store still reported "Verify OK".
  _vi_cust=0
  _vi_cfound=0
  if [ -d "$CUSTOM_CERT_DIR" ]; then
    for _vi_f in "$CUSTOM_CERT_DIR"/*; do
      [ -f "$_vi_f" ] || continue
      [ -f "$CERT_STAGE/${_vi_f##*/}" ] || continue
      _vi_cust=$((_vi_cust + 1))
      [ -f "$_vi_store/${_vi_f##*/}" ] && _vi_cfound=$((_vi_cfound + 1))
    done
  fi
  _vi_ctext=""
  [ "$_vi_cust" -gt 0 ] && _vi_ctext=", $_vi_cfound/$_vi_cust custom certs trusted"

  if [ "$_vi_want" -gt 0 ] && [ "$_vi_have" -ge "$_vi_want" ] &&
    [ "$_vi_found" -eq "$_vi_users" ] && [ "$_vi_cfound" -eq "$_vi_cust" ]; then
    log_info "Verify OK - $_vi_have certs live, $_vi_found/$_vi_users user certs trusted$_vi_ctext"
    write_stats "INJECT_OK=1" "INJECT_COUNT=$_vi_have" "LAST_INJECT=$(date +%s)"
    unset _vi_store _vi_want _vi_have _vi_users _vi_found _vi_f _vi_cust _vi_cfound _vi_ctext
    return 0
  fi

  log_error "Verify FAILED - staged $_vi_want, live $_vi_have, user certs trusted $_vi_found/$_vi_users$_vi_ctext"
  write_stats "INJECT_OK=0" "INJECT_COUNT=$_vi_have" "LAST_INJECT=$(date +%s)"
  unset _vi_store _vi_want _vi_have _vi_users _vi_found _vi_f _vi_cust _vi_cfound _vi_ctext
  return 1
}

# ── Android <= 13: tmpfs over /system/etc/security/cacerts ────────────────────
inject_low() {
  _il_ctx=$(read_selinux_context "$SYSTEM_CERT_DIR")
  if ! stage_certs; then
    log_error "Nothing mounted - the trust store is left as it is"
    write_stats "INJECT_OK=0"
    unset _il_ctx
    return 1
  fi

  if ! is_mounted "$SYSTEM_CERT_DIR"; then
    if ! mount -t tmpfs tmpfs "$SYSTEM_CERT_DIR" 2>/dev/null; then
      log_error "Failed to mount tmpfs on $SYSTEM_CERT_DIR"
      write_stats "INJECT_OK=0"
      unset _il_ctx
      return 1
    fi
    log_info "tmpfs mounted on $SYSTEM_CERT_DIR"
  else
    log_debug "tmpfs already present on $SYSTEM_CERT_DIR - refreshing contents"
  fi

  cp -f "$CERT_STAGE"/* "$SYSTEM_CERT_DIR"/ 2>/dev/null
  fix_permissions "$SYSTEM_CERT_DIR"
  apply_selinux_context "$_il_ctx" "$SYSTEM_CERT_DIR"

  unset _il_ctx
  verify_inject
}

# ── Android >= 14: bind mount over the conscrypt APEX cacerts ─────────────────
unmount_apex_overlay() {
  _ua_ver="$1"
  _ua_i=0
  while is_mounted "$APEX_CONSCRYPT_DIR" && [ "$_ua_i" -lt 10 ]; do
    umount "$APEX_CONSCRYPT_DIR" 2>/dev/null || umount -l "$APEX_CONSCRYPT_DIR" 2>/dev/null || break
    _ua_i=$((_ua_i + 1))
  done
  if [ -n "$_ua_ver" ]; then
    _ua_i=0
    while is_mounted "$_ua_ver/cacerts" && [ "$_ua_i" -lt 10 ]; do
      umount "$_ua_ver/cacerts" 2>/dev/null || umount -l "$_ua_ver/cacerts" 2>/dev/null || break
      _ua_i=$((_ua_i + 1))
    done
  fi
  # Drop stale binds inside the zygote / init namespaces too, otherwise every
  # re-inject stacks another mount on top of the previous one.
  if [ -n "$CMD_NSENTER" ]; then
    for _ua_pid in 1 $(list_pids_by_name zygote); do
      [ -d "/proc/$_ua_pid" ] || continue
      $CMD_NSENTER --mount="/proc/$_ua_pid/ns/mnt" -- umount "$APEX_CONSCRYPT_DIR" 2>/dev/null
      [ -n "$_ua_ver" ] &&
        $CMD_NSENTER --mount="/proc/$_ua_pid/ns/mnt" -- umount "$_ua_ver/cacerts" 2>/dev/null
    done
  fi
  unset _ua_ver _ua_i _ua_pid
  return 0
}

inject_high() {
  if ! stage_certs; then
    log_error "Nothing mounted - the trust store is left as it is"
    write_stats "INJECT_OK=0"
    return 1
  fi
  fix_permissions "$CERT_STAGE"

  _ih_ver=""
  for _ih_cand in /apex/com.android.conscrypt@*; do
    [ -d "$_ih_cand" ] || continue
    _ih_ver="$_ih_cand"
    break
  done
  log_debug "Versioned apex dir: ${_ih_ver:-none}"

  unmount_apex_overlay "$_ih_ver"

  # A staging tmpfs left by an interrupted run would stay mounted under the
  # new one for good.
  _ih_i=0
  while is_mounted "$TEMP_MOUNT" && [ "$_ih_i" -lt 10 ]; do
    umount "$TEMP_MOUNT" 2>/dev/null || umount -l "$TEMP_MOUNT" 2>/dev/null || break
    _ih_i=$((_ih_i + 1))
  done
  unset _ih_i
  rm -rf "$TEMP_MOUNT" 2>/dev/null
  mkdir -p "$TEMP_MOUNT" 2>/dev/null
  if ! mount -t tmpfs tmpfs "$TEMP_MOUNT" 2>/dev/null; then
    log_error "Failed to mount tmpfs on $TEMP_MOUNT"
    write_stats "INJECT_OK=0"
    unset _ih_ver
    return 1
  fi

  cp -f "$CERT_STAGE"/* "$TEMP_MOUNT"/ 2>/dev/null
  fix_permissions "$TEMP_MOUNT"
  apply_selinux_context "$(read_selinux_context "$APEX_CONSCRYPT_DIR")" "$TEMP_MOUNT"

  _ih_rc=0
  if mount -o bind "$TEMP_MOUNT" "$APEX_CONSCRYPT_DIR" 2>/dev/null; then
    log_debug "bind ok: $APEX_CONSCRYPT_DIR"
  else
    log_error "bind FAILED: $APEX_CONSCRYPT_DIR"
    _ih_rc=1
  fi

  if [ -n "$_ih_ver" ] && [ -d "$_ih_ver/cacerts" ]; then
    if mount -o bind "$TEMP_MOUNT" "$_ih_ver/cacerts" 2>/dev/null; then
      log_debug "bind ok: $_ih_ver/cacerts"
    else
      log_warn "bind failed: $_ih_ver/cacerts"
    fi
  fi

  # A zygote name match already covers both zygote and zygote64.
  if [ -n "$CMD_NSENTER" ]; then
    _ih_ns_ok=0
    _ih_ns_fail=0
    for _ih_pid in 1 $(list_pids_by_name zygote); do
      [ -d "/proc/$_ih_pid" ] || continue
      if $CMD_NSENTER --mount="/proc/$_ih_pid/ns/mnt" -- \
        mount --bind "$TEMP_MOUNT" "$APEX_CONSCRYPT_DIR" 2>/dev/null; then
        _ih_ns_ok=$((_ih_ns_ok + 1))
      else
        _ih_ns_fail=$((_ih_ns_fail + 1))
        log_debug "namespace bind failed for pid $_ih_pid"
      fi
      if [ -n "$_ih_ver" ] && [ -d "$_ih_ver/cacerts" ]; then
        $CMD_NSENTER --mount="/proc/$_ih_pid/ns/mnt" -- \
          mount --bind "$TEMP_MOUNT" "$_ih_ver/cacerts" 2>/dev/null
      fi
    done
    log_debug "namespace binds: $_ih_ns_ok ok, $_ih_ns_fail failed"
    unset _ih_ns_ok _ih_ns_fail
  else
    log_warn "Skipping namespace binds - nsenter is unavailable on this device"
  fi

  # The tmpfs stays alive through the bind mounts; only its staging path goes.
  umount "$TEMP_MOUNT" 2>/dev/null
  rmdir "$TEMP_MOUNT" 2>/dev/null

  if [ "$_ih_rc" -ne 0 ]; then
    write_stats "INJECT_OK=0"
    unset _ih_ver _ih_rc _ih_pid
    return 1
  fi

  unset _ih_ver _ih_rc _ih_pid _ih_cand
  verify_inject
}

# ── Public entry points ───────────────────────────────────────────────────────
inject_full() {
  if [ "$SDK" -ge 34 ]; then
    inject_high
  else
    inject_low
  fi
}

# Refresh the contents of an already active overlay. Much cheaper and far safer
# than tearing the mounts down and rebuilding them.
sync_store() {
  _ss_store=$(trust_store_dir)

  if ! is_mounted "$_ss_store"; then
    log_warn "Trust store is not overlaid - running a full inject instead"
    inject_full
    return $?
  fi

  if ! stage_certs; then
    log_error "Sync skipped - the trust store is left as it is"
    write_stats "INJECT_OK=0"
    unset _ss_store
    return 1
  fi

  # Propagate deletions: anything in the live store that is no longer staged.
  for _ss_f in "$_ss_store"/*; do
    [ -f "$_ss_f" ] || continue
    [ -f "$CERT_STAGE/${_ss_f##*/}" ] && continue
    rm -f "$_ss_f" 2>/dev/null
    log_debug "Removed stale cert ${_ss_f##*/}"
  done

  cp -f "$CERT_STAGE"/* "$_ss_store"/ 2>/dev/null
  fix_permissions "$_ss_store"
  if [ "$SDK" -le 33 ]; then
    apply_selinux_context "" "$_ss_store"
  fi

  unset _ss_store _ss_f
  verify_inject
}

# Live sync - sync_store plus counters, serialised against the watcher.
do_live_sync() {
  if ! lock_acquire "$SYNC_LOCK" 20; then
    log_warn "Live sync skipped - another sync is still running"
    return 1
  fi

  log_info "Live sync started"
  sync_store
  _dls_rc=$?

  _dls_n=$(read_stat LIVESYNCS)
  case "$_dls_n" in
    '' | *[!0-9]*) _dls_n=0 ;;
  esac
  write_stats "LIVESYNCS=$((_dls_n + 1))" "LAST_SYNC=$(date +%s)"

  lock_release "$SYNC_LOCK"
  log_info "Live sync finished (rc=$_dls_rc)"
  unset _dls_n
  return $_dls_rc
}
