#!/usr/bin/env bash
# Back up Splunk cold buckets to a tape-mounted filesystem.
# Tape may change between runs; we avoid duplication using a durable local ledger.
# Designed for environments where only ONE indexer can access tape.
# Performs atomic copy (temp -> verify -> move), idempotent, and resumable across tapes.
#
# Requires: bash, find, rsync, du, flock, date, mkdir, mv, awk, cut, mountpoint
# Optional: numfmt (for pretty sizes)

# If invoked as `sh backup-to-tape.sh` (or `sh -x ...`), re-exec under bash.
# The script relies on bash features such as arrays, [[ ]], and mapfile.
if [ -z "${BASH_VERSION:-}" ]; then
  if command -v bash >/dev/null 2>&1; then
    case "$-" in
      *x*) exec bash -x "$0" "$@" ;;
      *)   exec bash "$0" "$@" ;;
    esac
  fi
  printf '%s\n' "ERROR: This script requires bash." >&2
  exit 1
fi
 
set -Eeuo pipefail
 
############################
# ===== Configuration =====
############################

# Run with lower CPU/IO priority to avoid impacting a busy Splunk indexer
CPU_NICE_LEVEL="${CPU_NICE_LEVEL:-10}"
IO_NICE_CLASS="${IO_NICE_CLASS:-2}"       # 2=best-effort
IO_NICE_LEVEL="${IO_NICE_LEVEL:-7}"       # 0-7 (7=lowest)
RSYNC_BWLIMIT_MBIT="${RSYNC_BWLIMIT_MBIT:-0}"  # 0=unlimited; rsync copy rate cap in Mbit/s

ensure_low_priority() {
  # Avoid recursion if already re-execed
  if [[ -n "${LOW_PRIORITY_APPLIED:-}" ]]; then
    return 0
  fi

  if have_cmd nice; then
    export LOW_PRIORITY_APPLIED=1
    # Re-exec through bash so this works even when the script was launched as
    # `bash /path/script.sh` and does not rely on executable bit on $0.
    local shell_bin
    shell_bin="${BASH:-bash}"
    if have_cmd ionice; then
      exec ionice -c "$IO_NICE_CLASS" -n "$IO_NICE_LEVEL" nice -n "$CPU_NICE_LEVEL" "$shell_bin" "$0" "$@"
    else
      exec nice -n "$CPU_NICE_LEVEL" "$shell_bin" "$0" "$@"
    fi
  fi
}

# Where Splunk stores its index data on THIS indexer
SPLUNK_DB="${SPLUNK_DB:-/archdisk/splunk_db}"
 
# Tape/library mount path (appears as a directory)
BACKUP_ROOT="${BACKUP_ROOT:-/tape_mount/splunk_backup}"
 
# Optional: restrict to these indexes (space-separated). Empty = auto-discover all with colddb.
INDEXES="${INDEXES:-}"
 
# Include primary buckets (db_*) and replicated buckets (rb_*).
# Because only one indexer has tape, we default to include both.
INCLUDE_DB="${INCLUDE_DB:-1}"
INCLUDE_RB="${INCLUDE_RB:-1}"

# Skip buckets that are too new or have seen recent writes. This reduces the
# chance of competing with recent cold-roll activity or ongoing replication.
BUCKET_MIN_DIR_AGE_SECONDS="${BUCKET_MIN_DIR_AGE_SECONDS:-1800}"
BUCKET_MIN_QUIET_SECONDS="${BUCKET_MIN_QUIET_SECONDS:-900}"
 
# Logging and locking
LOG_DIR="${LOG_DIR:-/var/log/splunk-coldb-backup}"
LOG_FILE="${LOG_FILE:-$LOG_DIR/run.log}"
LOG_LEVEL="${LOG_LEVEL:-info}"   # trace|debug|info|warn|error
LOCK_FILE="${LOCK_FILE:-/var/lock/splunk_coldb_backup.lock}"
 
# Dry run (1 = simulate, do not copy)
DRY_RUN="${DRY_RUN:-0}"
 
# Verification method: "size" (du -sb) or "none"
VERIFY_METHOD="${VERIFY_METHOD:-size}"
 
# If a copy fails (e.g., tape full), stop the run to avoid thrashing
STOP_ON_COPY_ERROR="${STOP_ON_COPY_ERROR:-1}"
 
# --- Tape-aware dedupe & manifests ---
# Durable local state (do NOT put this on tape)
STATE_DIR="${STATE_DIR:-/var/lib/splunk-coldb-backup}"
LEDGER_FILE="${LEDGER_FILE:-$STATE_DIR/buckets_done.log}"       # Global list of completed buckets (index/bucket)
TAPE_MANIFEST_DIR="${TAPE_MANIFEST_DIR:-$STATE_DIR/tape_manifests}"
 
# Each run writes a manifest onto the currently-mounted tape (and mirrors it locally)
RUN_ID="${RUN_ID:-$(date +%Y%m%d_%H%M%S)}"
TAPE_MANIFEST_ON_TAPE="${TAPE_MANIFEST_ON_TAPE:-$BACKUP_ROOT/.manifest_$RUN_ID.txt}"
RUN_MANIFEST_INDEX="${RUN_MANIFEST_INDEX:-$STATE_DIR/run_${RUN_ID}_manifests.list}"
 
# Capacity control (soft stop before tape fills). Set e.g. 9500000000000 (≈9.5 TB). 0 = disabled.
SOFT_LIMIT_BYTES="${SOFT_LIMIT_BYTES:-0}"


# --- Tape changer integration ---
MTX_DEV="${MTX_DEV:-/dev/sch0}"
TAPE_DRIVE="${TAPE_DRIVE:-0}"          # Data Transfer Element index for mtx
SLOT_FIRST="${SLOT_FIRST:-1}"
SLOT_LAST="${SLOT_LAST:-40}"

# Media filtering: refuse cleaning cartridges and optionally restrict data tags.
DATA_TAPE_TAG_REGEX="${DATA_TAPE_TAG_REGEX:-}"

# Default LTFS integration for automatic mount/unmount during tape rotation.
LTFS_BIN="${LTFS_BIN:-ltfs}"
LTFS_DEVNAME="${LTFS_DEVNAME:-/dev/nst0}"
 
# Optional: define explicit mount/unmount commands if needed (StoreOpen/LTFS)
# If unset, the script defaults to LTFS mount and standard umount.
MOUNT_CMD="${MOUNT_CMD:-}"
UMOUNT_CMD="${UMOUNT_CMD:-}"
 
# Catalog mapping bucket -> tape VolumeTag
CATALOG_FILE="${CATALOG_FILE:-$STATE_DIR/catalog.csv}"
 
# When checking capacity, keep a safety buffer (avoid hard-full conditions)
MIN_FREE_BYTES="${MIN_FREE_BYTES:-200000000000}"  # 200GB safety margin
 
############################
# ====== Utilities  =======
############################
 
timestamp() { date -Is; }

append_main_log() {
  local level="$1"
  local msg="$2"
  local line

  should_log_level "$level" || return 0

  line="$(timestamp) level=$level run_id=$(kv_format "$RUN_ID") msg=$(kv_format "$msg")"
  printf '%s\n' "$line" | tee -a "$LOG_FILE" >&2
}

log() { append_main_log "info" "$1"; }
err() { append_main_log "error" "$1"; }
log_debug() { append_main_log "debug" "$1"; }
log_trace() { append_main_log "trace" "$1"; }

RUN_COMPLETION_REASON="not_started"
SPLUNK_RUN_START_EMITTED=0
SPLUNK_RUN_END_EMITTED=0

normalize_log_level() {
  local level="${1:-info}"
  level="${level,,}"
  case "$level" in
    trace|debug|info|warn|error) printf '%s' "$level" ;;
    err) printf '%s' "error" ;;
    *) printf '%s' "info" ;;
  esac
}

log_level_rank() {
  case "$(normalize_log_level "$1")" in
    trace) echo 10 ;;
    debug) echo 20 ;;
    info)  echo 30 ;;
    warn)  echo 40 ;;
    error) echo 50 ;;
  esac
}

should_log_level() {
  local msg_rank cfg_rank
  msg_rank="$(log_level_rank "$1")"
  cfg_rank="$(log_level_rank "$LOG_LEVEL")"
  (( msg_rank >= cfg_rank ))
}

epoch_ms_now() {
  if [[ -n "${EPOCHREALTIME:-}" ]]; then
    local sec frac
    sec="${EPOCHREALTIME%.*}"
    frac="${EPOCHREALTIME#*.}"
    frac="${frac}000"
    echo "${sec}${frac:0:3}"
  else
    echo "$(( $(date +%s) * 1000 ))"
  fi
}

kv_quote() {
  local v="$1"
  v="${v//\\/\\\\}"
  v="${v//\"/\\\"}"
  printf '"%s"' "$v"
}

kv_format() {
  local v="$1"
  if [[ "$v" =~ [[:space:]] ]]; then
    kv_quote "$v"
  else
    printf '%s' "$v"
  fi
}

append_splunk_event() {
  local event_name="$1"
  shift || true

  local now_iso
  local pair key value level="info"
  local -a pairs=()
  local line

  now_iso="$(date -Is)"
  for pair in "$@"; do
    [[ "$pair" == *=* ]] || continue
    key="${pair%%=*}"
    value="${pair#*=}"
    if [[ "$key" == "level" ]]; then
      level="$value"
      continue
    fi
    pairs+=("$pair")
  done

  should_log_level "$level" || return 0

  line="$now_iso level=$(kv_format "$level") event=$event_name run_id=$(kv_format "$RUN_ID")"

  for pair in "${pairs[@]}"; do
    [[ "$pair" == *=* ]] || continue
    key="${pair%%=*}"
    value="${pair#*=}"
    line+=" $key=$(kv_format "$value")"
  done

  mkdir -p "$(dirname "$LOG_FILE")"
  printf '%s\n' "$line" >> "$LOG_FILE"
}

emit_run_start_once() {
  if [[ "$SPLUNK_RUN_START_EMITTED" == "1" ]]; then
    return 0
  fi

  append_splunk_event "run_start" "level=info"
  SPLUNK_RUN_START_EMITTED=1
}

emit_run_end_once() {
  local run_status="$1"
  local completion_reason="$2"

  if [[ "$SPLUNK_RUN_START_EMITTED" != "1" || "$SPLUNK_RUN_END_EMITTED" == "1" ]]; then
    return 0
  fi

  append_splunk_event "run_end" "level=info" "status=$run_status" "completion_reason=$completion_reason"
  SPLUNK_RUN_END_EMITTED=1
}

on_script_exit() {
  local exit_code="$1"
  local run_status="success"
  local completion_reason="$RUN_COMPLETION_REASON"

  if [[ "$SPLUNK_RUN_START_EMITTED" != "1" ]]; then
    return 0
  fi

  if (( exit_code != 0 )); then
    run_status="failed"
    if [[ -z "$completion_reason" || "$completion_reason" == "completed" || "$completion_reason" == "not_started" ]]; then
      completion_reason="exit_${exit_code}"
    fi
  elif [[ -z "$completion_reason" || "$completion_reason" == "not_started" ]]; then
    completion_reason="completed"
  fi

  emit_run_end_once "$run_status" "$completion_reason"
}

append_splunk_summary() {
  local run_status="$1"
  local last_used_tape_tag="$2"
  local tape_tags_csv="$3"
  local indexes_seen="$4"
  local total="$5"
  local skipped="$6"
  local skipped_active="$7"
  local copied="$8"
  local failed="$9"
  local bytes_written="${10}"
  local duration_seconds="${11}"
  local duration_ms="${12}"
  local completion_reason="${13}"
  local tapes_touched_count="${14}"
  local host

  host="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo unknown)"

  append_splunk_event "run_summary" \
    "level=info" \
    "status=$run_status" \
    "completion_reason=$completion_reason" \
    "host=$host" \
    "dry_run=$DRY_RUN" \
    "verify=$VERIFY_METHOD" \
    "include_db=$INCLUDE_DB" \
    "include_rb=$INCLUDE_RB" \
    "last_used_volume_tag=$last_used_tape_tag" \
    "volume_tags_seen=$tape_tags_csv" \
    "tapes_touched=$tapes_touched_count" \
    "indexes_seen=$indexes_seen" \
    "total_buckets_seen=$total" \
    "buckets_copied=$copied" \
    "buckets_failed=$failed" \
    "buckets_skipped=$skipped" \
    "buckets_skipped_active=$skipped_active" \
    "bytes_written=$bytes_written" \
    "soft_limit_bytes=$SOFT_LIMIT_BYTES" \
    "duration_seconds=$duration_seconds" \
    "duration_ms=$duration_ms"
}

declare -A TAPES_TOUCHED_MAP=()
declare -a TAPES_TOUCHED_ORDER=()

record_tape_touched() {
  local tag="$1"
  [[ -n "$tag" ]] || return 0

  if [[ -z "${TAPES_TOUCHED_MAP[$tag]:-}" ]]; then
    TAPES_TOUCHED_MAP["$tag"]=1
    TAPES_TOUCHED_ORDER+=("$tag")
  fi
}

declare -A LEDGER_CACHE=()
LEDGER_CACHE_LOADED=0
MANIFEST_MIRROR_DIRTY=0
MANIFEST_APPENDS_SINCE_SYNC=0
MANIFEST_SYNC_EVERY=100
LAST_KNOWN_TAPE_TAG=""
 
have_cmd()  { command -v "$1" >/dev/null 2>&1; }

have_path_cmd() {
  local cmd="$1"

  if [[ "$cmd" == */* ]]; then
    [[ -x "$cmd" ]]
  else
    have_cmd "$cmd"
  fi
}
 
human_bytes() {
  if have_cmd numfmt; then numfmt --to=iec "$1"; else echo "$1"; fi
}

rsync_bwlimit_kib() {
  (( RSYNC_BWLIMIT_MBIT > 0 )) || return 1
  echo $(( RSYNC_BWLIMIT_MBIT * 1000 * 1000 / 8 / 1024 ))
}
 
acquire_lock() {
  # Use flock as a wrapper process so child processes do not inherit a lock FD.
  # This avoids stale lock behavior when long-lived subprocesses survive script exit.
  if [[ "${LOCK_HELD:-0}" == "1" ]]; then
    return 0
  fi

  local shell_bin flock_status
  shell_bin="${BASH:-bash}"

  mkdir -p "$(dirname "$LOCK_FILE")"
  if env LOCK_HELD=1 flock -n --close "$LOCK_FILE" "$shell_bin" "$0" "$@"; then
    exit 0
  fi

  flock_status=$?
  if (( flock_status == 1 )); then
    err "Another backup is already running (lock: $LOCK_FILE). Exiting."
  else
    err "Failed to acquire lock (flock exit=$flock_status, lock: $LOCK_FILE). This is not an active-lock conflict; check flock compatibility/permissions and script path."
  fi
  exit 1
}
 
# Guard: BACKUP_ROOT and SPLUNK_DB must be disjoint trees.
# Without this, a misconfigured BACKUP_ROOT pointing inside SPLUNK_DB would pass
# validate_copy_paths() (both the src and dst checks succeed independently)
# and rsync would write into the live Splunk index directory.
validate_path_safety() {
  local real_splunk_db real_backup_root
  # realpath -m normalises without requiring the paths to exist yet
  real_splunk_db="$(realpath -m -- "$SPLUNK_DB")"
  real_backup_root="$(realpath -m -- "$BACKUP_ROOT")"

  if [[ -z "$real_splunk_db" || -z "$real_backup_root" ]]; then
    err "Cannot resolve SPLUNK_DB or BACKUP_ROOT for path safety check."
    RUN_COMPLETION_REASON="path_safety_check_failed"
    exit 1
  fi

  if [[ "$real_backup_root" == "$real_splunk_db" || "$real_backup_root" == "$real_splunk_db/"* ]]; then
    err "BACKUP_ROOT ($BACKUP_ROOT) must not be the same as or under SPLUNK_DB ($SPLUNK_DB). Refusing to run."
    RUN_COMPLETION_REASON="path_safety_check_failed"
    exit 1
  fi

  if [[ "$real_splunk_db" == "$real_backup_root" || "$real_splunk_db" == "$real_backup_root/"* ]]; then
    err "SPLUNK_DB ($SPLUNK_DB) must not be the same as or under BACKUP_ROOT ($BACKUP_ROOT). Refusing to run."
    RUN_COMPLETION_REASON="path_safety_check_failed"
    exit 1
  fi
}

# Ensure BACKUP_ROOT is an actual mount, not an empty local dir
# Set SKIP_MOUNT_CHECK=1 for testing without real tape hardware
ensure_mount() {
  if [[ "${SKIP_MOUNT_CHECK:-0}" == "1" ]]; then
    return 0
  fi
  if ! mountpoint -q "$BACKUP_ROOT"; then
    err "Backup root $BACKUP_ROOT is not a mountpoint. Tape/library not mounted? Aborting."
    RUN_COMPLETION_REASON="mount_check_failed"
    exit 3
  fi
}
 
# Index discovery: list directories under SPLUNK_DB that contain colddb
discover_indexes() {
  if [[ -n "$INDEXES" ]]; then
    echo "$INDEXES"
    return
  fi
 
  find "$SPLUNK_DB" -mindepth 1 -maxdepth 1 -type d 2>/dev/null \
    | while read -r idxdir; do
        [[ -d "$idxdir/colddb" ]] && basename "$idxdir"
      done | sort
}
 
# List bucket directories for an index, under colddb, matching db_* and/or rb_*
list_buckets_for_index() {
  local idx="$1"
  local src="$SPLUNK_DB/$idx/colddb"
  [[ -d "$src" ]] || return 0
 
  local pattern=""
  if [[ "$INCLUDE_DB" == "1" && "$INCLUDE_RB" == "1" ]]; then
    pattern='/(db|rb)_.+'
  elif [[ "$INCLUDE_DB" == "1" ]]; then
    pattern='/db_.+'
  elif [[ "$INCLUDE_RB" == "1" ]]; then
    pattern='/rb_.+'
  else
    return 0
  fi
 
  find "$src" -mindepth 1 -maxdepth 1 -type d -regextype posix-extended -regex ".+${pattern}" \
    | sort
}

path_mtime_epoch() {
  local path="$1"
  stat --format='%Y' -- "$path" 2>/dev/null
}

collect_bucket_metadata() {
  local bucket="$1"

  find "$bucket" -printf '%T@ %y %s\n' 2>/dev/null \
    | awk 'BEGIN{max=0; sum=0} {mtime=int($1); if (mtime>max) max=mtime; if ($2=="f") sum+=$3} END{printf "%s %s\n", sum+0, max+0}'
}

bucket_skip_reason() {
  local bucket="$1"
  local newest_mtime="$2"
  local now dir_mtime dir_age quiet_age

  now=$(date +%s)

  if (( BUCKET_MIN_DIR_AGE_SECONDS > 0 )); then
    dir_mtime="$(path_mtime_epoch "$bucket")"
    if [[ -z "$dir_mtime" ]]; then
      printf 'cannot determine directory mtime'
      return 0
    fi

    dir_age=$(( now - dir_mtime ))
    if (( dir_age < BUCKET_MIN_DIR_AGE_SECONDS )); then
      printf 'recently rolled: directory age=%ss threshold=%ss' "$dir_age" "$BUCKET_MIN_DIR_AGE_SECONDS"
      return 0
    fi
  fi

  if (( BUCKET_MIN_QUIET_SECONDS > 0 )); then
    if [[ -z "$newest_mtime" || "$newest_mtime" == "0" ]]; then
      printf 'cannot determine newest content mtime'
      return 0
    fi

    quiet_age=$(( now - newest_mtime ))
    if (( quiet_age < BUCKET_MIN_QUIET_SECONDS )); then
      printf 'recently touched: newest content age=%ss threshold=%ss' "$quiet_age" "$BUCKET_MIN_QUIET_SECONDS"
      return 0
    fi
  fi

  return 1
}
 
require_cmds() {
  local missing=0
    for c in bash find rsync flock date mkdir mv awk mountpoint df mtx stat realpath; do
    have_cmd "$c" || { err "Missing required command: $c"; missing=1; }
  done

  if [[ -z "$MOUNT_CMD" ]] && ! have_path_cmd "$LTFS_BIN"; then
    err "Missing required LTFS mount command: $LTFS_BIN"
    missing=1
  fi

  if [[ -z "$UMOUNT_CMD" ]] && ! have_cmd umount; then
    err "Missing required command: umount"
    missing=1
  fi

  # Validate tape addressing env vars are integers to prevent regex injection in grep -E.
  local tape_int_bad=0
  for _var_pair in "TAPE_DRIVE:$TAPE_DRIVE" "SLOT_FIRST:$SLOT_FIRST" "SLOT_LAST:$SLOT_LAST"; do
    local _name="${_var_pair%%:*}" _val="${_var_pair#*:}"
    [[ "$_val" =~ ^[0-9]+$ ]] || { err "$_name must be a non-negative integer; got: $_val"; tape_int_bad=1; }
  done
  (( tape_int_bad == 0 )) || missing=1

  (( missing == 0 )) || { err "Install required commands and re-run."; RUN_COMPLETION_REASON="missing_required_commands"; exit 1; }
}

mount_tape_filesystem() {
  if [[ -n "$MOUNT_CMD" ]]; then
    eval "$MOUNT_CMD"
  else
    "$LTFS_BIN" "$BACKUP_ROOT" -o "devname=$LTFS_DEVNAME"
  fi
}

unmount_tape_filesystem() {
  if [[ -n "$UMOUNT_CMD" ]]; then
    eval "$UMOUNT_CMD"
  else
    umount "$BACKUP_ROOT"
  fi
}
 
tape_status() {
  mtx -f "$MTX_DEV" status
}

get_loaded_tape_line() {
  tape_status | grep -E "^[[:space:]]*Data Transfer Element ${TAPE_DRIVE}:" | head -n 1
}

drive_has_loaded_media() {
  local line
  line="$(get_loaded_tape_line || true)"
  [[ "$line" == *":Full"* ]]
}

# Returns VolumeTag of currently loaded tape (empty if none loaded)
get_loaded_tape_tag() {
  local line
  line="$(get_loaded_tape_line || true)"
  if [[ "$line" =~ VolumeTag=([^[:space:]]+) ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  fi
}

loaded_tape_is_cleaning() {
  local line
  line="$(get_loaded_tape_line || true)"
  [[ "$line" == *"Cleaning Cartridge"* ]]
}

# Returns the slot number from which the current tape was loaded (best-effort; empty if unknown)
get_loaded_from_slot() {
  local line
  line="$(get_loaded_tape_line || true)"
  if [[ "$line" =~ Storage[[:space:]]Element[[:space:]]([0-9]+)[[:space:]]Loaded ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  fi
}

# Find next candidate slot that is Full, not yet marked as FULL in state
# We’ll track full tapes in: $STATE_DIR/tapes_full.list
TAPES_FULL_LIST="${TAPES_FULL_LIST:-$STATE_DIR/tapes_full.list}"

slot_status_line() {
  local slot="$1"
  tape_status | grep -E "^[[:space:]]*Storage Element ${slot}:" | head -n 1
}

slot_is_full() {
  local line
  line="$(slot_status_line "$1" || true)"
  [[ "$line" == *"Full"* ]]
}

slot_is_cleaning() {
  local line
  line="$(slot_status_line "$1" || true)"
  [[ "$line" == *"Cleaning Cartridge"* ]]
}

slot_volumetag() {
  local line
  line="$(slot_status_line "$1" || true)"
  if [[ "$line" =~ VolumeTag=([^[:space:]]+) ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  fi
}

slot_has_allowed_tag() {
  local tag="$1"
  [[ -z "$DATA_TAPE_TAG_REGEX" || "$tag" =~ $DATA_TAPE_TAG_REGEX ]]
}
 
tape_mark_full() {
  local tag="$1"
  mkdir -p "$STATE_DIR"
  touch "$TAPES_FULL_LIST"
  grep -Fxq "$tag" "$TAPES_FULL_LIST" || echo "$tag" >> "$TAPES_FULL_LIST"
}
 
tape_is_marked_full() {
  local tag="$1"
  [[ -f "$TAPES_FULL_LIST" ]] && grep -Fxq "$tag" "$TAPES_FULL_LIST"
}
 
# Returns "slot:tag" for the next usable tape
find_next_tape_slot() {
  local s tag
  for ((s=SLOT_FIRST; s<=SLOT_LAST; s++)); do
    if slot_is_full "$s"; then
      if slot_is_cleaning "$s"; then
        log "Skip slot $s: cleaning cartridge"
        continue
      fi
      tag="$(slot_volumetag "$s")"
      [[ -n "$tag" ]] || continue
      if ! slot_has_allowed_tag "$tag"; then
        log "Skip slot $s: tag $tag does not match DATA_TAPE_TAG_REGEX"
        continue
      fi
      if ! tape_is_marked_full "$tag"; then
        echo "$s:$tag"
        return 0
      fi
    fi
  done
  return 1
}
 
# Load tape from slot -> drive
load_tape_from_slot() {
  local slot="$1"
  log "Loading tape from slot $slot into drive $TAPE_DRIVE ..."
  mtx -f "$MTX_DEV" load "$slot" "$TAPE_DRIVE"
}
 
# Unload tape from drive -> slot
unload_tape_to_slot() {
  local slot="$1"
  log "Unloading tape from drive $TAPE_DRIVE back to slot $slot ..."
  mtx -f "$MTX_DEV" unload "$slot" "$TAPE_DRIVE"
}
 
# Ensure a tape is loaded & mounted; if no tape, load next
ensure_tape_ready() {
  local tag line
  local drive_full=0

  line="$(get_loaded_tape_line || true)"
  if [[ "$line" == *":Full"* ]]; then
    drive_full=1
  fi

  if [[ "$line" =~ VolumeTag=([^[:space:]]+) ]]; then
    tag="${BASH_REMATCH[1]}"
  else
    tag=""
  fi

  if [[ "$line" == *"Cleaning Cartridge"* ]]; then
    err "Loaded media in drive $TAPE_DRIVE is a cleaning cartridge. Refusing to use it for backups."
    RUN_COMPLETION_REASON="loaded_cleaning_cartridge"
    exit 14
  fi
  if [[ -n "$tag" ]] && ! slot_has_allowed_tag "$tag"; then
    err "Loaded media VolumeTag=$tag does not match DATA_TAPE_TAG_REGEX. Refusing to use it for backups."
    RUN_COMPLETION_REASON="loaded_tape_tag_rejected"
    exit 15
  fi
  if [[ -n "$tag" ]]; then
    LAST_KNOWN_TAPE_TAG="$tag"
  elif (( drive_full == 1 )); then
    # Some mtx implementations may not report VolumeTag on the drive line.
    # If media is loaded, do not attempt another load operation.
    if [[ -n "$LAST_KNOWN_TAPE_TAG" ]]; then
      tag="$LAST_KNOWN_TAPE_TAG"
      log_debug "Drive $TAPE_DRIVE is loaded but VolumeTag is missing in status; reusing last known VolumeTag=$tag"
    else
      log_debug "Drive $TAPE_DRIVE is loaded but VolumeTag is missing in status; continuing without a known VolumeTag"
    fi
  fi

  if [[ -z "$tag" && $drive_full -eq 0 ]]; then
    local next
    if ! next="$(find_next_tape_slot)"; then
      err "No available non-cleaning data tapes found in slots $SLOT_FIRST-$SLOT_LAST."
      RUN_COMPLETION_REASON="no_available_tapes"
      exit 10
    fi
    local slot="${next%%:*}"
    local ntag="${next##*:}"
    load_tape_from_slot "$slot"
    # mount if needed
    mount_tape_filesystem
    ensure_mount
    tag="$ntag"
    LAST_KNOWN_TAPE_TAG="$tag"
  elif [[ "${SKIP_MOUNT_CHECK:-0}" != "1" ]] && ! mountpoint -q "$BACKUP_ROOT"; then
    mount_tape_filesystem
  fi
  # If a tape is already loaded, still verify the mountpoint is valid
  ensure_mount
  echo "$tag"
}
 
tape_free_bytes() {
  # avail bytes on the mounted tape filesystem
  df -B1 --output=avail "$BACKUP_ROOT" | tail -n 1 | awk '{print $1}'
}

record_manifest_path() {
  local manifest_path="$1"
  [[ -n "$manifest_path" ]] || return 0
  mkdir -p "$STATE_DIR"
  touch "$RUN_MANIFEST_INDEX"
  grep -Fxq -- "$manifest_path" "$RUN_MANIFEST_INDEX" || echo "$manifest_path" >> "$RUN_MANIFEST_INDEX"
}

manifest_mirror_path() {
  printf '%s/%s\n' "$TAPE_MANIFEST_DIR" "$(basename "$TAPE_MANIFEST_ON_TAPE")"
}

sync_tape_manifest_mirror() {
  local mirror_path

  if [[ "$DRY_RUN" == "1" || "$MANIFEST_MIRROR_DIRTY" != "1" ]]; then
    return 0
  fi

  mirror_path="$(manifest_mirror_path)"
  mkdir -p "$TAPE_MANIFEST_DIR"
  cp -f "$TAPE_MANIFEST_ON_TAPE" "$mirror_path" || true
  MANIFEST_MIRROR_DIRTY=0
  MANIFEST_APPENDS_SINCE_SYNC=0
}
 
# Rotate tape: mark current as full, unmount, unload, load next, mount
rotate_tape() {
  local curtag="$1"
  local curslot
  curslot="$(get_loaded_from_slot || true)"
 
  log "Rotating tape. Marking current tape as FULL: $curtag"
  tape_mark_full "$curtag"
 
  log "Finalizing tape manifest for $curtag"
  echo "# EndOfTape VolumeTag=$curtag Time=$(timestamp) Run=$RUN_ID" >> "$TAPE_MANIFEST_ON_TAPE" || true
  MANIFEST_MIRROR_DIRTY=1
  sync_tape_manifest_mirror
 
  unmount_tape_filesystem || true
 
  # If we know the original slot, unload back to it; otherwise try the next empty slot strategy (not shown)
  if [[ -n "$curslot" ]]; then
    unload_tape_to_slot "$curslot"
  else
    err "Could not determine original slot for loaded tape. Please unload manually."
    RUN_COMPLETION_REASON="unknown_loaded_tape_slot"
    exit 11
  fi
 
  local next
  if ! next="$(find_next_tape_slot)"; then
    err "No remaining tapes available after marking $curtag full."
    RUN_COMPLETION_REASON="no_remaining_tapes"
    exit 12
  fi
  local slot="${next%%:*}"
  local ntag="${next##*:}"
 
  load_tape_from_slot "$slot"
  mount_tape_filesystem
  ensure_mount
 
  # Start a new manifest on the new tape (new RUN_ID optional; keeping same RUN_ID is fine)
  TAPE_MANIFEST_ON_TAPE="$BACKUP_ROOT/.manifest_${RUN_ID}_${ntag}.txt"
  : > "$TAPE_MANIFEST_ON_TAPE" || { err "Cannot write manifest on new tape: $TAPE_MANIFEST_ON_TAPE"; RUN_COMPLETION_REASON="cannot_write_rotated_manifest"; exit 13; }
  record_manifest_path "$TAPE_MANIFEST_ON_TAPE"
  MANIFEST_MIRROR_DIRTY=1
  sync_tape_manifest_mirror
 
  log "Tape rotated. Now using VolumeTag=$ntag"
}
 
# --- Ledger & Manifests ---

load_ledger_cache() {
  local rel

  LEDGER_CACHE=()
  if [[ -f "$LEDGER_FILE" ]]; then
    while IFS= read -r rel; do
      [[ -n "$rel" ]] || continue
      LEDGER_CACHE["$rel"]=1
    done < "$LEDGER_FILE"
  fi
  LEDGER_CACHE_LOADED=1
}
 
already_in_ledger() {
  local rel="$1"  # format: index/bucketname
  (( LEDGER_CACHE_LOADED )) || load_ledger_cache
  [[ -n "${LEDGER_CACHE[$rel]:-}" ]]
}
 
mark_ledger() {
  local rel="$1"
  if already_in_ledger "$rel"; then
    return 0
  fi
  mkdir -p "$(dirname "$LEDGER_FILE")"
  { flock -x 9; echo "$rel" >> "$LEDGER_FILE"; } 9>>"$LEDGER_FILE"
  LEDGER_CACHE["$rel"]=1
}
 
append_to_tape_manifest() {
  local rel="$1"
  local mirror_path

  echo "$rel" >> "$TAPE_MANIFEST_ON_TAPE"
  if [[ "$DRY_RUN" != "1" ]]; then
    mirror_path="$(manifest_mirror_path)"
    mkdir -p "$TAPE_MANIFEST_DIR"
    echo "$rel" >> "$mirror_path"
  fi
}
 
init_catalog() {
  mkdir -p "$STATE_DIR"
  if [[ ! -f "$CATALOG_FILE" ]]; then
    echo "time,run_id,volume_tag,index,bucket,bytes,dst_path" > "$CATALOG_FILE"
  fi
}
 
catalog_add() {
  local vol="$1" idx="$2" bucket="$3" bytes="$4" dst="$5"
  local line
  line="$(date -Is),$RUN_ID,$vol,$idx,$bucket,$bytes,$dst"
  { flock -x 8; echo "$line" >> "$CATALOG_FILE"; } 8>>"$CATALOG_FILE"
}
 
# --- Copy & Verify ---

regular_file_bytes() {
  local path="$1"
  find "$path" -type f -exec stat --format='%s' {} + 2>/dev/null | awk '{s+=$1}END{print s+0}'
}

validate_copy_paths() {
  local src_bucket="$1"
  local dst_index_dir="$2"
  local bucket_name src_parent

  bucket_name=$(basename -- "$src_bucket")
  src_parent=$(dirname -- "$src_bucket")

  case "$bucket_name" in
    db_*|rb_*) ;;
    *)
      err "Refusing unexpected bucket name outside db_*/rb_*: $src_bucket"
      return 1
      ;;
  esac

  if [[ "$src_parent" != */colddb ]]; then
    err "Refusing source outside a direct colddb bucket path: $src_bucket"
    return 1
  fi

  case "$src_bucket" in
    "$SPLUNK_DB"/*/colddb/*) ;;
    *)
      err "Refusing source outside SPLUNK_DB colddb tree: $src_bucket"
      return 1
      ;;
  esac

  case "$dst_index_dir" in
    "$BACKUP_ROOT"/*) ;;
    *)
      err "Refusing destination outside BACKUP_ROOT: $dst_index_dir"
      return 1
      ;;
  esac

  return 0
}

cleanup_tmp_dir() {
  local tmp_dir="$1"
  local real_tmp real_backup_root

  if [[ -z "$BACKUP_ROOT" || "$BACKUP_ROOT" != /* ]]; then
    err "BACKUP_ROOT is not set or not absolute"
    return 1
  fi

  real_backup_root=$(realpath -e -- "$BACKUP_ROOT") || {
    err "Cannot resolve BACKUP_ROOT: $BACKUP_ROOT"
    return 1
  }

  real_tmp=$(realpath -e -- "$tmp_dir") || {
    err "Invalid temp path: $tmp_dir"
    return 1
  }

  if [[ ! -d "$real_tmp" ]]; then
    err "Temp path is not a directory: $real_tmp"
    return 1
  fi

  case "$real_tmp" in
    "$real_backup_root"/*/.tmp/*.partial-*)
      rm -rf -- "$real_tmp"
      ;;
    *)
      err "Refusing to remove unexpected temp path: $real_tmp"
      return 1
      ;;
  esac
}

cleanup_stale_tmp_dirs() {
  local tmp_dir cleaned=0

  while IFS= read -r -d '' tmp_dir; do
    if cleanup_tmp_dir "$tmp_dir"; then
      (( cleaned++ )) || true
      log "Removed stale temp directory: $tmp_dir"
    fi
  done < <(find "$BACKUP_ROOT" -type d -path "$BACKUP_ROOT/*/.tmp/*.partial-*" -mmin +60 -print0 2>/dev/null)

  if (( cleaned > 0 )); then
    log "Removed $cleaned stale temp director$( (( cleaned == 1 )) && printf 'y' || printf 'ies' ) before starting copies"
  fi
}
 
verify_copy() {
  local src_bytes="$1"
  local dst="$2"
  case "$VERIFY_METHOD" in
    size)
      # Compare total size of regular files only (avoids filesystem-dependent
      # directory entry sizes differing between e.g. ext4 and tmpfs/LTFS)
      local d
      d=$(regular_file_bytes "$dst")
      if [[ "$src_bytes" != "$d" ]]; then
        err "Size mismatch: src=$src_bytes dst=$d"
        return 1
      fi
      return 0
      ;;
    none) return 0 ;;
    *)
      err "Unknown VERIFY_METHOD=$VERIFY_METHOD"; return 1 ;;
  esac
}
 
copy_bucket_atomic() {
  local src_bucket="$1"     # /.../colddb/db_* or rb_*
  local dst_index_dir="$2"  # BACKUP_ROOT/<index>
  local src_bytes="$3"
  local -a rsync_args
  local rsync_bwlimit_kibps

  validate_copy_paths "$src_bucket" "$dst_index_dir" || return 1
 
  local bucket_name
  bucket_name=$(basename -- "$src_bucket")
  local final_dst="$dst_index_dir/$bucket_name"
  local tmp_dir="$dst_index_dir/.tmp/${bucket_name}.partial-$$"
 
  # If the bucket directory already exists on the mounted tape filesystem, skip.
  if [[ -d "$final_dst" ]]; then
    log "Skip (exists on tape): $final_dst"
    return 0
  fi
 
  mkdir -p "$dst_index_dir/.tmp"
 
  if [[ "$DRY_RUN" == "1" ]]; then
    log "[DRY-RUN] Would copy: $src_bucket -> $final_dst"
    return 0
  fi

  rsync_args=(-aH --numeric-ids)
  if rsync_bwlimit_kibps="$(rsync_bwlimit_kib)"; then
    rsync_args+=("--bwlimit=$rsync_bwlimit_kibps")
  fi
 
  # ---------- >>> REAL COPY HAPPENS HERE <<< ----------
  if ! rsync "${rsync_args[@]}" \
    -- "$src_bucket"/ "$tmp_dir"/; then
    err "Copy failed before verification: $src_bucket (temp at $tmp_dir). Cleaning up."
    cleanup_tmp_dir "$tmp_dir" || true
    return 1
  fi
  # ---------------------------------------------------
 
  if verify_copy "$src_bytes" "$tmp_dir"; then
    mv -- "$tmp_dir" "$final_dst"
    log "Backed up: $src_bucket -> $final_dst"
  else
    err "Verification failed: $src_bucket (temp at $tmp_dir). Cleaning up."
    cleanup_tmp_dir "$tmp_dir" || true
    return 1
  fi
}
 
main() {
  local run_started_epoch run_finished_epoch run_duration_seconds
  local run_started_ms run_finished_ms run_duration_ms
  local tape_tags_csv=""
  local tapes_touched_count=0
  TAPES_TOUCHED_MAP=()
  TAPES_TOUCHED_ORDER=()

  ensure_low_priority "$@"
  mkdir -p "$LOG_DIR"
  touch "$LOG_FILE"
  require_cmds
 
  acquire_lock "$@"
  trap 'on_script_exit $?' EXIT
  RUN_COMPLETION_REASON="completed"
  run_started_epoch="$(date +%s)"
  run_started_ms="$(epoch_ms_now)"
  emit_run_start_once
  validate_path_safety

  mkdir -p "$BACKUP_ROOT"
  if [[ "$DRY_RUN" != "1" ]]; then
    mkdir -p "$STATE_DIR" "$TAPE_MANIFEST_DIR"
    touch "$LEDGER_FILE"
  fi
 
  log "=== Splunk cold bucket backup started ==="
  log "Run: id=$RUN_ID dry_run=$DRY_RUN verify=$VERIFY_METHOD"
  log "Source: $SPLUNK_DB -> Destination: $BACKUP_ROOT"
 
  local current_tape_tag
  if [[ "$DRY_RUN" == "1" ]]; then
    current_tape_tag="$(get_loaded_tape_tag || true)"
    current_tape_tag="${current_tape_tag:-DRY-RUN}"
    record_tape_touched "$current_tape_tag"
    log "DRY_RUN=1: skipping tape load/rotation and state mutations"
  else
    init_catalog
    touch "$TAPES_FULL_LIST"
    current_tape_tag="$(ensure_tape_ready)"
    record_tape_touched "$current_tape_tag"
    # Create or touch this run's manifest on the tape (after mount)
    : > "$TAPE_MANIFEST_ON_TAPE" || { err "Cannot write manifest on tape: $TAPE_MANIFEST_ON_TAPE"; RUN_COMPLETION_REASON="cannot_write_initial_manifest"; exit 4; }
    record_manifest_path "$TAPE_MANIFEST_ON_TAPE"
    MANIFEST_MIRROR_DIRTY=1
    sync_tape_manifest_mirror
    cleanup_stale_tmp_dirs
  fi
  load_ledger_cache
  log "Current tape: $current_tape_tag"
 
  local indexes
  mapfile -t indexes < <(discover_indexes)
  if (( ${#indexes[@]} == 0 )); then
    err "No indexes with colddb found under $SPLUNK_DB"
    RUN_COMPLETION_REASON="no_indexes_found"
    exit 1
  fi
 
  local -a buckets
  local total=0 skipped=0 skipped_active=0 copied=0 failed=0
  local current_bytes=0
 
  for idx in "${indexes[@]}"; do
    local src_colddb="$SPLUNK_DB/$idx/colddb"
    local dst_idx_dir="$BACKUP_ROOT/$idx"
    mkdir -p "$dst_idx_dir/.tmp"
 
    log "--- Index: $idx ---"
 
    mapfile -t buckets < <(list_buckets_for_index "$idx")
    if (( ${#buckets[@]} == 0 )); then
      log "No matching buckets in $src_colddb"
      continue
    fi
 
    for b in "${buckets[@]}"; do
      (( total++ )) || true
      local bucket_name
      local bucket_bytes bucket_newest_mtime
      bucket_name=$(basename "$b")
      local rel="$idx/$bucket_name"
      local final_dst="$dst_idx_dir/$bucket_name"

      read -r bucket_bytes bucket_newest_mtime < <(collect_bucket_metadata "$b")
 
      # Ledger-based dedupe across tapes/runs
      if already_in_ledger "$rel"; then
        (( skipped++ )) || true
        log "Skip (ledger): $rel already archived"
        continue
      fi
 
      # If already present on the currently-mounted tape, also skip
      if [[ -d "$final_dst" ]]; then
        (( skipped++ )) || true
        log "Skip (exists on tape): $final_dst"
        # Also mark to ledger to avoid future copies if not yet recorded
        if [[ "$DRY_RUN" != "1" ]]; then
          mark_ledger "$rel"
          append_to_tape_manifest "$rel"
        fi
        continue
      fi

      local skip_reason
      if skip_reason="$(bucket_skip_reason "$b" "$bucket_newest_mtime")"; then
        (( skipped_active++ )) || true
        log "Skip (active): $rel $skip_reason"
        continue
      fi

      if [[ "$DRY_RUN" != "1" ]]; then
        # Make sure tape is loaded/mounted; refresh tag (in case of rotation)
        current_tape_tag="$(ensure_tape_ready)"
        record_tape_touched "$current_tape_tag"

        local free_bytes
        free_bytes="$(tape_free_bytes)"

        # If not enough space (including safety buffer), rotate
        if (( free_bytes < bucket_bytes + MIN_FREE_BYTES )); then
          log "Not enough space on tape VolumeTag=$current_tape_tag. Free=$(human_bytes "$free_bytes"), need=$(human_bytes "$bucket_bytes") + buffer=$(human_bytes "$MIN_FREE_BYTES"). Rotating..."
          rotate_tape "$current_tape_tag"
          current_tape_tag="$(ensure_tape_ready)"
          record_tape_touched "$current_tape_tag"
        fi

        # Capacity-aware batching (soft limit)
        if (( SOFT_LIMIT_BYTES > 0 )) && (( current_bytes + bucket_bytes > SOFT_LIMIT_BYTES )); then
          log "Soft tape limit reached at $(human_bytes "$current_bytes"); next bucket $rel ($(human_bytes "$bucket_bytes")) would exceed limit $(human_bytes "$SOFT_LIMIT_BYTES")."
          log "Stopping run cleanly for tape rotation. Re-run after mounting next tape."
          RUN_COMPLETION_REASON="soft_limit_stop"
          break 2  # Leave both loops
        fi
      fi
 
      if copy_bucket_atomic "$b" "$dst_idx_dir" "$bucket_bytes"; then
        ((copied++)) || true
        if [[ "$DRY_RUN" != "1" ]]; then
          mark_ledger "$rel"
          append_to_tape_manifest "$rel"
          catalog_add "$current_tape_tag" "$idx" "$bucket_name" "$bucket_bytes" "$final_dst"
          current_bytes=$(( current_bytes + bucket_bytes ))
        fi
      else
        ((failed++)) || true
        err "Copy failed: $rel"
        if [[ "$STOP_ON_COPY_ERROR" == "1" ]]; then
          err "STOP_ON_COPY_ERROR=1 -> stopping early (tape full or I/O error?)."
          RUN_COMPLETION_REASON="copy_error_stop"
          break 2
        fi
      fi
    done
  done

  sync_tape_manifest_mirror

  run_finished_epoch="$(date +%s)"
  run_finished_ms="$(epoch_ms_now)"
  run_duration_seconds=$(( run_finished_epoch - run_started_epoch ))
  run_duration_ms=$(( run_finished_ms - run_started_ms ))
  (( run_duration_ms >= 0 )) || run_duration_ms=$(( run_duration_seconds * 1000 ))

  tapes_touched_count=${#TAPES_TOUCHED_ORDER[@]}
  if (( tapes_touched_count > 0 )); then
    tape_tags_csv="$(IFS=,; echo "${TAPES_TOUCHED_ORDER[*]}")"
  else
    tape_tags_csv="$current_tape_tag"
    [[ -n "$tape_tags_csv" ]] && tapes_touched_count=1 || tapes_touched_count=0
  fi
 
  log "=== Summary ==="
  log "Total buckets seen: $total"
  log "Already present or ledger-skipped: $skipped"
  log "Skipped due to recent roll or activity: $skipped_active"
  log "Copied this run: $copied"
  log "Failed: $failed"
  if (( SOFT_LIMIT_BYTES > 0 )); then
    log "Bytes written this run (approx): $(human_bytes "$current_bytes") / $(human_bytes "$SOFT_LIMIT_BYTES")"
  fi
  if [[ -f "$RUN_MANIFEST_INDEX" ]]; then
    while read -r manifest_path; do
      [[ -n "$manifest_path" ]] || continue
      log "Run manifest written to: $manifest_path"
      log "Local manifest mirror: $TAPE_MANIFEST_DIR/$(basename "$manifest_path")"
    done < "$RUN_MANIFEST_INDEX"
  elif [[ "$DRY_RUN" != "1" ]]; then
    log "Run manifest written to: $TAPE_MANIFEST_ON_TAPE"
    log "Local manifest mirror: $TAPE_MANIFEST_DIR/$(basename "$TAPE_MANIFEST_ON_TAPE")"
  fi
  if (( failed == 0 )); then
    append_splunk_summary "success" "$current_tape_tag" "$tape_tags_csv" "${#indexes[@]}" "$total" "$skipped" "$skipped_active" "$copied" "$failed" "$current_bytes" "$run_duration_seconds" "$run_duration_ms" "$RUN_COMPLETION_REASON" "$tapes_touched_count"
  else
    append_splunk_summary "failed" "$current_tape_tag" "$tape_tags_csv" "${#indexes[@]}" "$total" "$skipped" "$skipped_active" "$copied" "$failed" "$current_bytes" "$run_duration_seconds" "$run_duration_ms" "$RUN_COMPLETION_REASON" "$tapes_touched_count"
  fi
  log "Structured run events appended to main log: $LOG_FILE"
  log "Ledger file: $LEDGER_FILE"
  log "=== Done ==="
 
  (( failed == 0 )) || exit 2
}
 
main "$@"