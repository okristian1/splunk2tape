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
 
# Verification method: sha256 (content readback), size (fast metadata check), or none.
VERIFY_METHOD="${VERIFY_METHOD:-sha256}"
 
# If a copy fails (e.g., tape full), stop the run to avoid thrashing
STOP_ON_COPY_ERROR="${STOP_ON_COPY_ERROR:-1}"

# If 1, fail the run when post-run sweep still finds eligible uncopied buckets.
STRICT_COMPLETION="${STRICT_COMPLETION:-0}"

# If 1, continue running additional passes until no eligible buckets remain.
RUN_UNTIL_DRAINED="${RUN_UNTIL_DRAINED:-1}"
# Optional safety guard: max passes when RUN_UNTIL_DRAINED=1. 0 = unlimited.
MAX_DRAIN_PASSES="${MAX_DRAIN_PASSES:-0}"
 
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

  trap - EXIT TERM

  if ! unmount_tape_if_mounted; then
    err "Failed to unmount tape filesystem at $BACKUP_ROOT during exit cleanup."
    if (( exit_code == 0 )); then
      exit_code=17
      completion_reason="unmount_failed"
    fi
  fi

  if [[ "$SPLUNK_RUN_START_EMITTED" != "1" ]]; then
    exit "$exit_code"
  fi

  if (( exit_code != 0 )); then
    run_status="failed"
    if [[ -z "$completion_reason" || "$completion_reason" == "completed" || "$completion_reason" == "not_started" ]]; then
      case "$exit_code" in
        2)  completion_reason="copy_failures" ;;
        3)  completion_reason="mount_failed" ;;
        10) completion_reason="no_available_tapes" ;;
        11) completion_reason="unknown_loaded_tape_slot" ;;
        12) completion_reason="no_remaining_tapes" ;;
        13) completion_reason="cannot_write_rotated_manifest" ;;
        14) completion_reason="loaded_cleaning_cartridge" ;;
        15) completion_reason="loaded_tape_tag_rejected" ;;
        16) completion_reason="tape_load_failed" ;;
        17) completion_reason="unmount_failed" ;;
        18) completion_reason="manifest_finalize_failed" ;;
        19) completion_reason="loaded_tape_identity_unknown" ;;
        20) completion_reason="manifest_mirror_failed" ;;
        21) completion_reason="loaded_tape_identity_mismatch" ;;
        *)  completion_reason="exit_${exit_code}" ;;
      esac
    fi
  elif [[ -z "$completion_reason" || "$completion_reason" == "not_started" ]]; then
    completion_reason="completed"
  fi

  emit_run_end_once "$run_status" "$completion_reason"
  exit "$exit_code"
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
LAST_KNOWN_TAPE_TAG=""
declare -A MANIFEST_ENTRIES_WRITTEN=()
 
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
  # Keep this Bash process as systemd's main PID so KillMode=mixed delivers
  # TERM to the shell that owns the LTFS cleanup trap.
  local lock_fd

  mkdir -p "$(dirname "$LOCK_FILE")"
  if ! exec {lock_fd}>>"$LOCK_FILE"; then
    err "Cannot open lock file: $LOCK_FILE"
    exit 1
  fi

  if ! flock -n "$lock_fd"; then
    exec {lock_fd}>&-
    err "Another backup is already running (lock: $LOCK_FILE). Exiting."
    exit 1
  fi
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

  if [[ "$VERIFY_METHOD" == "sha256" ]]; then
    if ! have_cmd sha256sum && ! have_cmd shasum; then
      err "VERIFY_METHOD=sha256 requires sha256sum or shasum."
      missing=1
    fi
    for c in cmp mktemp sort xargs; do
      have_cmd "$c" || { err "VERIFY_METHOD=sha256 requires $c"; missing=1; }
    done
    if ! printf '' | LC_ALL=C sort -z >/dev/null 2>&1; then
      err "VERIFY_METHOD=sha256 requires sort with NUL-delimited (-z) support."
      missing=1
    fi
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
  # Mount output is sent to stderr: this function runs inside
  # $(ensure_tape_ready) in the copy loop, and any stdout would pollute the
  # captured VolumeTag return value.
  if [[ -n "$MOUNT_CMD" ]]; then
    eval "$MOUNT_CMD" >&2
  else
    "$LTFS_BIN" "$BACKUP_ROOT" -o "devname=$LTFS_DEVNAME" >&2
  fi
}

unmount_tape_filesystem() {
  if [[ -n "$UMOUNT_CMD" ]]; then
    eval "$UMOUNT_CMD" >&2
  else
    umount "$BACKUP_ROOT" >&2
  fi
}

unmount_tape_if_mounted() {
  [[ "$DRY_RUN" != "1" ]] || return 0
  mountpoint -q "$BACKUP_ROOT" || return 0

  log "Unmounting tape filesystem before script exit"
  unmount_tape_filesystem || return 1
  if mountpoint -q "$BACKUP_ROOT"; then
    err "Unmount command returned success but $BACKUP_ROOT is still mounted."
    return 1
  fi
}
 
tape_status() {
  mtx -f "$MTX_DEV" status
}

get_loaded_tape_line() {
  tape_status | grep -E "^[[:space:]]*Data Transfer Element ${TAPE_DRIVE}:" | head -n 1
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
  # "Full" means a cartridge is present in the slot (the slot is occupied),
  # not that the tape has no remaining capacity. Match the state as a whole
  # word: mtx reports writable tapes as "Not Full", which a bare *Full*
  # substring test would also match. Note the flip side: firmware that
  # reports a writable data cartridge as "Not Full" would be skipped by this
  # test; if your library behaves that way, adjust the selection criteria.
  [[ "$line" =~ :Full([^[:alnum:]]|$) ]]
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
  # Real mtx prints load progress to stdout. Redirect it to stderr: this
  # function runs inside $(ensure_tape_ready) in the copy loop, and any
  # stdout would pollute the captured VolumeTag return value (mount output
  # is handled the same way in mount_tape_filesystem).
  mtx -f "$MTX_DEV" load "$slot" "$TAPE_DRIVE" >&2
}
 
# Unload tape from drive -> slot
unload_tape_to_slot() {
  local slot="$1"
  log "Unloading tape from drive $TAPE_DRIVE back to slot $slot ..."
  mtx -f "$MTX_DEV" unload "$slot" "$TAPE_DRIVE"
}

verify_loaded_tape_identity() {
  local expected_tag="$1"
  local expected_slot="$2"
  local line actual_slot actual_tag=""

  line="$(get_loaded_tape_line || true)"
  actual_slot="$(get_loaded_from_slot || true)"

  if [[ "$line" == *"Cleaning Cartridge"* ]]; then
    err "Refusing to mount cleaning cartridge from slot $expected_slot."
    return 1
  fi
  if [[ -n "$actual_slot" && "$actual_slot" != "$expected_slot" ]]; then
    err "Loaded tape came from slot $actual_slot; expected slot $expected_slot."
    return 1
  fi
  if [[ "$line" =~ VolumeTag=([^[:space:]]+) ]]; then
    actual_tag="${BASH_REMATCH[1]}"
    if [[ "$actual_tag" != "$expected_tag" ]]; then
      err "Loaded tape VolumeTag=$actual_tag; expected $expected_tag from slot $expected_slot."
      return 1
    fi
  elif [[ "$actual_slot" != "$expected_slot" ]]; then
    err "Cannot verify loaded tape identity: mtx reports neither the expected slot nor a VolumeTag."
    return 1
  fi
}

# Sync LAST_KNOWN_TAPE_TAG in the *parent* shell. ensure_tape_ready runs
# inside $(...) in the copy loop, so any assignment it makes to
# LAST_KNOWN_TAPE_TAG is lost when the subshell exits. Call this in the
# parent after a successful `current_tape_tag="$(ensure_tape_ready)"` so the
# fallback tag stays current for later ensure_tape_ready calls.
sync_known_tape_tag() {
  if [[ -n "${1:-}" ]]; then
    LAST_KNOWN_TAPE_TAG="$1"
  fi
}
 
# Ensure a tape is loaded & mounted; if no tape, load next
ensure_tape_ready() {
  local tag line
  # "Full" in mtx output means a cartridge is present (the drive is
  # occupied), not that the tape has no remaining capacity.
  local cartridge_in_drive=0

  line="$(get_loaded_tape_line || true)"
  # Whole-word match: "Not Full" must not count as Full.
  if [[ "$line" =~ :Full([^[:alnum:]]|$) ]]; then
    cartridge_in_drive=1
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
  elif (( cartridge_in_drive == 1 )); then
    # Some mtx implementations may not report VolumeTag on the drive line.
    # If media is loaded, do not attempt another load operation.
    # (Assignments made in this $(...) subshell do not persist to the
    # parent shell; sync_known_tape_tag() is called there after we return.)
    if [[ -n "$LAST_KNOWN_TAPE_TAG" ]]; then
      tag="$LAST_KNOWN_TAPE_TAG"
      log_debug "Drive $TAPE_DRIVE is loaded but VolumeTag is missing in status; reusing last known VolumeTag=$tag"
    else
      err "Loaded tape identity is unknown (mtx reports no VolumeTag and this run has no prior tape tag); refusing to write."
      RUN_COMPLETION_REASON="loaded_tape_identity_unknown"
      exit 19
    fi
  fi

  if [[ -z "$tag" && $cartridge_in_drive -eq 0 ]]; then
    local next
    if ! next="$(find_next_tape_slot)"; then
      err "No available non-cleaning data tapes found in slots $SLOT_FIRST-$SLOT_LAST."
      RUN_COMPLETION_REASON="no_available_tapes"
      exit 10
    fi
    local slot="${next%%:*}"
    local ntag="${next##*:}"
    # Check load and mount explicitly: this function runs inside $(...) in
    # the copy loop, where errexit is not relied upon, and a pre-existing
    # mountpoint must not mask a failed load.
    if ! load_tape_from_slot "$slot"; then
      err "Failed to load tape from slot $slot into drive $TAPE_DRIVE."
      RUN_COMPLETION_REASON="tape_load_failed"
      exit 16
    fi
    if ! verify_loaded_tape_identity "$ntag" "$slot"; then
      RUN_COMPLETION_REASON="loaded_tape_identity_mismatch"
      exit 21
    fi
    # mount if needed
    if ! mount_tape_filesystem; then
      err "Failed to mount tape filesystem at $BACKUP_ROOT."
      RUN_COMPLETION_REASON="mount_failed"
      exit 3
    fi
    ensure_mount
    tag="$ntag"
    LAST_KNOWN_TAPE_TAG="$tag"
  elif [[ "${SKIP_MOUNT_CHECK:-0}" != "1" ]] && ! mountpoint -q "$BACKUP_ROOT"; then
    if ! mount_tape_filesystem; then
      err "Failed to mount tape filesystem at $BACKUP_ROOT."
      RUN_COMPLETION_REASON="mount_failed"
      exit 3
    fi
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
  if ! cp -f "$TAPE_MANIFEST_ON_TAPE" "$mirror_path"; then
    err "Could not refresh local manifest mirror: $mirror_path"
    return 0
  fi
  MANIFEST_MIRROR_DIRTY=0
}

require_manifest_mirror() {
  if [[ "$MANIFEST_MIRROR_DIRTY" == "1" ]]; then
    err "Local tape manifest mirror is still out of date."
    RUN_COMPLETION_REASON="manifest_mirror_failed"
    exit 20
  fi
}
 
# Rotate tape: mark current as full, unmount, unload, load next, mount
rotate_tape() {
  local curtag="$1"
  local curslot
  curslot="$(get_loaded_from_slot || true)"
 
  log "Finalizing tape manifest for $curtag"
  if ! printf '# EndOfTape VolumeTag=%s Time=%s Run=%s\n' "$curtag" "$(timestamp)" "$RUN_ID" >> "$TAPE_MANIFEST_ON_TAPE"; then
    err "Failed to append end-of-tape marker to $TAPE_MANIFEST_ON_TAPE; leaving cartridge loaded."
    RUN_COMPLETION_REASON="manifest_finalize_failed"
    exit 18
  fi
  MANIFEST_MIRROR_DIRTY=1
  sync_tape_manifest_mirror
  require_manifest_mirror
 
  if ! unmount_tape_if_mounted; then
    err "Failed to unmount $BACKUP_ROOT; refusing to unload tape $curtag."
    RUN_COMPLETION_REASON="unmount_failed"
    exit 17
  fi

  log "Rotating tape. Marking current tape as FULL: $curtag"
  tape_mark_full "$curtag"
 
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
 
  # Check load and mount explicitly (rotate_tape runs in the parent shell,
  # so a bare failure would only exit with an unexplained code, no reason).
  if ! load_tape_from_slot "$slot"; then
    err "Failed to load next tape from slot $slot into drive $TAPE_DRIVE during rotation."
    RUN_COMPLETION_REASON="tape_load_failed"
    exit 16
  fi
  if ! verify_loaded_tape_identity "$ntag" "$slot"; then
    RUN_COMPLETION_REASON="loaded_tape_identity_mismatch"
    exit 21
  fi
  if ! mount_tape_filesystem; then
    err "Failed to mount new tape filesystem at $BACKUP_ROOT during rotation."
    RUN_COMPLETION_REASON="mount_failed"
    exit 3
  fi
  ensure_mount
  # rotate_tape runs in the parent shell, so this persists across later
  # ensure_tape_ready calls (useful when the new drive line lacks a tag).
  LAST_KNOWN_TAPE_TAG="$ntag"
 
  # Start a new manifest on the new tape (new RUN_ID optional; keeping same RUN_ID is fine)
  TAPE_MANIFEST_ON_TAPE="$BACKUP_ROOT/.manifest_${RUN_ID}_${ntag}.txt"
  : > "$TAPE_MANIFEST_ON_TAPE" || { err "Cannot write manifest on new tape: $TAPE_MANIFEST_ON_TAPE"; RUN_COMPLETION_REASON="cannot_write_rotated_manifest"; exit 13; }
  record_manifest_path "$TAPE_MANIFEST_ON_TAPE"
  MANIFEST_MIRROR_DIRTY=1
  sync_tape_manifest_mirror
  require_manifest_mirror
 
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
  {
    flock -x 9 || exit 1
    printf '%s\n' "$rel" >&9 || exit 1
  } 9>>"$LEDGER_FILE" || return 1
  LEDGER_CACHE["$rel"]=1
}
 
append_to_tape_manifest() {
  local rel="$1"
  local mirror_path
  local manifest_entry_key="$TAPE_MANIFEST_ON_TAPE|$rel"

  if [[ -z "${MANIFEST_ENTRIES_WRITTEN[$manifest_entry_key]:-}" ]]; then
    printf '%s\n' "$rel" >> "$TAPE_MANIFEST_ON_TAPE" || return 1
    MANIFEST_ENTRIES_WRITTEN["$manifest_entry_key"]=1
  fi
  if [[ "$DRY_RUN" != "1" ]]; then
    mirror_path="$(manifest_mirror_path)"
    mkdir -p "$TAPE_MANIFEST_DIR"
    if [[ ! -f "$mirror_path" ]]; then
      cp -f "$TAPE_MANIFEST_ON_TAPE" "$mirror_path" || {
        err "Could not refresh local manifest mirror: $mirror_path"
        MANIFEST_MIRROR_DIRTY=1
        return 1
      }
    else
      if ! printf '%s\n' "$rel" >> "$mirror_path"; then
        err "Could not append to local manifest mirror: $mirror_path"
        MANIFEST_MIRROR_DIRTY=1
        return 1
      fi
    fi
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
  {
    flock -x 8 || exit 1
    if ! awk -F, -v volume="$vol" -v idx_name="$idx" -v bucket_name="$bucket" \
      'NR > 1 && $3 == volume && $4 == idx_name && $5 == bucket_name { found = 1 } END { exit !found }' \
      "$CATALOG_FILE"; then
      printf '%s\n' "$line" >&8 || exit 1
    fi
  } 8>>"$CATALOG_FILE"
}

record_committed_bucket() {
  local vol="$1" idx="$2" bucket="$3" bytes="$4" dst="$5"
  local rel="$idx/$bucket"

  append_to_tape_manifest "$rel" || return 1
  catalog_add "$vol" "$idx" "$bucket" "$bytes" "$dst" || return 1
  mark_ledger "$rel"
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
 
checksum_tree() {
  local root="$1"
  local files_file

  (
    cd -- "$root" || exit 1
    files_file="$(mktemp "${TMPDIR:-/tmp}/splunk-tape-files.XXXXXX")" || exit 1
    if ! find . -type f -print0 | LC_ALL=C sort -z > "$files_file"; then
      rm -f -- "$files_file"
      exit 1
    fi
    if [[ -s "$files_file" ]]; then
      if have_cmd sha256sum; then
        xargs -0 sha256sum < "$files_file"
      else
        xargs -0 shasum -a 256 < "$files_file"
      fi
      local checksum_status=$?
      rm -f -- "$files_file"
      exit "$checksum_status"
    fi
    rm -f -- "$files_file"
  )
}

verify_copy() {
  local src_bytes="$1"
  local src_bucket="$2"
  local dst="$3"
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
    sha256)
      local verify_dir
      verify_dir="$(mktemp -d "${TMPDIR:-/tmp}/splunk-tape-verify.XXXXXX")" || {
        err "Could not create temporary files for SHA-256 verification."
        return 1
      }
      if ! checksum_tree "$src_bucket" > "$verify_dir/source"; then
        err "Could not hash source bucket: $src_bucket"
        rm -rf -- "$verify_dir"
        return 1
      fi
      if ! checksum_tree "$dst" > "$verify_dir/tape"; then
        err "Could not read back and hash copied bucket: $dst"
        rm -rf -- "$verify_dir"
        return 1
      fi
      if ! cmp -s -- "$verify_dir/source" "$verify_dir/tape"; then
        err "SHA-256 verification failed: $src_bucket -> $dst"
        rm -rf -- "$verify_dir"
        return 1
      fi
      rm -rf -- "$verify_dir"
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
 
  if verify_copy "$src_bytes" "$src_bucket" "$tmp_dir"; then
    # Check the final rename explicitly: this function is called inside an
    # `if`, where errexit is disabled, so a failed mv must not be treated
    # as a successful commit (no success log, no ledger/catalog entry).
    if ! mv -- "$tmp_dir" "$final_dst"; then
      err "Final rename failed: $tmp_dir -> $final_dst (target path exists? not writable?). Cleaning up."
      cleanup_tmp_dir "$tmp_dir" || true
      return 1
    fi
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
  local final_exit_code=0
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
  trap 'exit 143' TERM
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
    sync_known_tape_tag "$current_tape_tag"
    record_tape_touched "$current_tape_tag"
    # Create or touch this run's manifest on the tape (after mount)
    : > "$TAPE_MANIFEST_ON_TAPE" || { err "Cannot write manifest on tape: $TAPE_MANIFEST_ON_TAPE"; RUN_COMPLETION_REASON="cannot_write_initial_manifest"; exit 4; }
    record_manifest_path "$TAPE_MANIFEST_ON_TAPE"
    MANIFEST_MIRROR_DIRTY=1
    sync_tape_manifest_mirror
    require_manifest_mirror
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
  local -a skipped_active_samples=()
  local -a pending_eligible_samples=()
  local -a pending_active_samples=()
  local total=0 skipped=0 skipped_active=0 copied=0 failed=0
  local pending_eligible=0 pending_active=0
  local current_bytes=0
  local pass_num=0 copied_before_pass=0 copied_this_pass=0

  while :; do
    (( pass_num++ )) || true
    copied_before_pass=$copied
    pending_eligible=0
    pending_active=0
    pending_eligible_samples=()
    pending_active_samples=()

    log "=== Copy pass $pass_num started ==="

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
        if (( pass_num == 1 )); then
          (( total++ )) || true
        fi
      local bucket_name
      bucket_name=$(basename "$b")
      local rel="$idx/$bucket_name"
      local final_dst="$dst_idx_dir/$bucket_name"

      # Cheap checks before the metadata scan: the ledger lookup and the
      # destination test are O(1), while collect_bucket_metadata() runs a
      # recursive find over the whole bucket. Do not replace that find with
      # a directory-mtime cache: nested file writes do not update the
      # directory mtime, so such a cache would go stale.
      # Ledger-based dedupe across tapes/runs
      if already_in_ledger "$rel"; then
        if (( pass_num == 1 )); then
          (( skipped++ )) || true
        fi
        log "Skip (ledger): $rel already archived"
        continue
      fi
 
      # If already present on the currently-mounted tape, also skip
      if [[ -d "$final_dst" ]]; then
        if (( pass_num == 1 )); then
          (( skipped++ )) || true
        fi
        log "Skip (exists on tape): $final_dst"
        if [[ "$DRY_RUN" != "1" ]]; then
          local existing_bytes existing_newest_mtime
          read -r existing_bytes existing_newest_mtime < <(collect_bucket_metadata "$b")
          if ! verify_copy "$existing_bytes" "$b" "$final_dst"; then
            err "Existing tape bucket failed recovery verification: $final_dst"
            ((failed++)) || true
            if [[ "$STOP_ON_COPY_ERROR" == "1" ]]; then
              RUN_COMPLETION_REASON="existing_bucket_verification_failed"
              break 2
            fi
            continue
          fi
          if ! record_committed_bucket "$current_tape_tag" "$idx" "$bucket_name" "$existing_bytes" "$final_dst"; then
            err "Could not repair catalog/manifest/ledger metadata for existing tape bucket: $final_dst"
            ((failed++)) || true
            if [[ "$STOP_ON_COPY_ERROR" == "1" ]]; then
              RUN_COMPLETION_REASON="metadata_recovery_failed"
              break 2
            fi
          fi
        fi
        continue
      fi

      local bucket_bytes bucket_newest_mtime
      read -r bucket_bytes bucket_newest_mtime < <(collect_bucket_metadata "$b")

      local skip_reason
      if skip_reason="$(bucket_skip_reason "$b" "$bucket_newest_mtime")"; then
        if (( pass_num == 1 )); then
          (( skipped_active++ )) || true
          if (( ${#skipped_active_samples[@]} < 5 )); then
            skipped_active_samples+=("$rel")
          fi
        fi
        log "Skip (active): $rel $skip_reason"
        continue
      fi

      if [[ "$DRY_RUN" != "1" ]]; then
        # Cheap per-bucket liveness check: the tape filesystem must still be
        # mounted (LTFS unmounts on media removal). `mtx status` is an
        # expensive full library scan, so only redo it when the mount is
        # gone, not for every bucket.
        if [[ "${SKIP_MOUNT_CHECK:-0}" != "1" ]] && ! mountpoint -q "$BACKUP_ROOT"; then
          log "Mountpoint $BACKUP_ROOT no longer mounted; re-checking tape state"
          current_tape_tag="$(ensure_tape_ready)"
          sync_known_tape_tag "$current_tape_tag"
          record_tape_touched "$current_tape_tag"
        fi

        local free_bytes
        free_bytes="$(tape_free_bytes)"

        # If not enough space (including safety buffer), rotate
        if (( free_bytes < bucket_bytes + MIN_FREE_BYTES )); then
          log "Not enough space on tape VolumeTag=$current_tape_tag. Free=$(human_bytes "$free_bytes"), need=$(human_bytes "$bucket_bytes") + buffer=$(human_bytes "$MIN_FREE_BYTES"). Rotating..."
          rotate_tape "$current_tape_tag"
          current_tape_tag="$(ensure_tape_ready)"
          sync_known_tape_tag "$current_tape_tag"
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
          current_bytes=$(( current_bytes + bucket_bytes ))
          if ! record_committed_bucket "$current_tape_tag" "$idx" "$bucket_name" "$bucket_bytes" "$final_dst"; then
            err "Could not record catalog/manifest/ledger metadata for committed bucket: $final_dst"
            ((failed++)) || true
            if [[ "$STOP_ON_COPY_ERROR" == "1" ]]; then
              RUN_COMPLETION_REASON="metadata_recording_failed"
              break 2
            fi
          fi
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

    # Post-pass sweep: detect buckets still pending after this pass.
    for idx in "${indexes[@]}"; do
      local dst_idx_dir="$BACKUP_ROOT/$idx"

      mapfile -t buckets < <(list_buckets_for_index "$idx")
      for b in "${buckets[@]}"; do
        local bucket_name rel final_dst
        local _bucket_bytes _bucket_newest_mtime
        local pending_skip_reason

        bucket_name=$(basename "$b")
        rel="$idx/$bucket_name"
        final_dst="$dst_idx_dir/$bucket_name"

        if already_in_ledger "$rel"; then
          continue
        fi

        if [[ -d "$final_dst" ]]; then
          continue
        fi

        read -r _bucket_bytes _bucket_newest_mtime < <(collect_bucket_metadata "$b")
        if pending_skip_reason="$(bucket_skip_reason "$b" "$_bucket_newest_mtime")"; then
          (( pending_active++ )) || true
          if (( ${#pending_active_samples[@]} < 5 )); then
            pending_active_samples+=("$rel")
          fi
          continue
        fi

        (( pending_eligible++ )) || true
        if (( ${#pending_eligible_samples[@]} < 5 )); then
          pending_eligible_samples+=("$rel")
        fi
      done
    done

    copied_this_pass=$(( copied - copied_before_pass ))
    log "=== Copy pass $pass_num done: copied_this_pass=$copied_this_pass pending_eligible=$pending_eligible pending_active=$pending_active ==="

    if [[ "$RUN_COMPLETION_REASON" == "soft_limit_stop" || "$RUN_COMPLETION_REASON" == "copy_error_stop" ]]; then
      break
    fi

    if [[ "$RUN_UNTIL_DRAINED" != "1" || "$DRY_RUN" == "1" ]]; then
      if [[ "$DRY_RUN" == "1" ]]; then
        # Dry runs never persist buckets, so draining would loop forever.
        log "Dry run: single pass only; stopping drain loop"
      fi
      break
    fi

    if (( pending_eligible == 0 )); then
      break
    fi

    if (( copied_this_pass == 0 )); then
      if [[ "$DRY_RUN" == "1" ]]; then
        log "Dry run: no copies performed; stopping after pass $pass_num"
      else
        RUN_COMPLETION_REASON="pending_eligible_no_progress"
        log "Pending eligible buckets remain but no progress in pass $pass_num; stopping to avoid infinite loop."
      fi
      break
    fi

    if (( MAX_DRAIN_PASSES > 0 && pass_num >= MAX_DRAIN_PASSES )); then
      RUN_COMPLETION_REASON="max_drain_passes_reached"
      log "Reached MAX_DRAIN_PASSES=$MAX_DRAIN_PASSES with pending eligible buckets still present."
      break
    fi
  done

  sync_tape_manifest_mirror

  if [[ "$MANIFEST_MIRROR_DIRTY" == "1" ]]; then
    err "Local tape manifest mirror is still out of date."
    RUN_COMPLETION_REASON="manifest_mirror_failed"
    final_exit_code=20
  fi

  if ! unmount_tape_if_mounted; then
    err "Failed to unmount tape filesystem at $BACKUP_ROOT after copying."
    RUN_COMPLETION_REASON="unmount_failed"
    final_exit_code=17
  fi

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

  if [[ "$RUN_COMPLETION_REASON" == "completed" ]] && (( skipped_active > 0 )); then
    RUN_COMPLETION_REASON="completed_with_active_deferred_buckets"
  fi

  if [[ "$RUN_COMPLETION_REASON" == "completed" ]] && (( pending_eligible > 0 )); then
    RUN_COMPLETION_REASON="completed_with_pending_eligible_buckets"
  fi

  if (( skipped_active > 0 )); then
    log "Note: $skipped_active bucket(s) were deferred by activity guards (BUCKET_MIN_DIR_AGE_SECONDS=$BUCKET_MIN_DIR_AGE_SECONDS, BUCKET_MIN_QUIET_SECONDS=$BUCKET_MIN_QUIET_SECONDS)."
    if (( ${#skipped_active_samples[@]} > 0 )); then
      log "Deferred bucket examples: ${skipped_active_samples[*]}"
    fi
    log "Set BUCKET_MIN_DIR_AGE_SECONDS=0 and BUCKET_MIN_QUIET_SECONDS=0 to copy all eligible colddb buckets immediately."
  fi

  if (( pending_eligible > 0 )); then
    log "Post-run sweep: $pending_eligible eligible bucket(s) remain uncopied after this pass."
    if (( ${#pending_eligible_samples[@]} > 0 )); then
      log "Pending eligible bucket examples: ${pending_eligible_samples[*]}"
    fi
  fi

  if (( pending_active > 0 )); then
    log "Post-run sweep: $pending_active additional bucket(s) currently deferred by activity guards."
    if (( ${#pending_active_samples[@]} > 0 )); then
      log "Pending active bucket examples: ${pending_active_samples[*]}"
    fi
  fi

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
  if (( failed == 0 && final_exit_code == 0 )); then
    append_splunk_summary "success" "$current_tape_tag" "$tape_tags_csv" "${#indexes[@]}" "$total" "$skipped" "$skipped_active" "$copied" "$failed" "$current_bytes" "$run_duration_seconds" "$run_duration_ms" "$RUN_COMPLETION_REASON" "$tapes_touched_count"
  else
    append_splunk_summary "failed" "$current_tape_tag" "$tape_tags_csv" "${#indexes[@]}" "$total" "$skipped" "$skipped_active" "$copied" "$failed" "$current_bytes" "$run_duration_seconds" "$run_duration_ms" "$RUN_COMPLETION_REASON" "$tapes_touched_count"
  fi
  log "Structured run events appended to main log: $LOG_FILE"
  log "Ledger file: $LEDGER_FILE"
  log "=== Done ==="

  if (( final_exit_code != 0 )); then
    exit "$final_exit_code"
  fi

  if [[ "$STRICT_COMPLETION" == "1" ]] && (( pending_eligible > 0 )); then
    err "STRICT_COMPLETION=1 and pending eligible buckets remain ($pending_eligible). Failing run."
    exit 6
  fi
 
  (( failed == 0 )) || exit 2
}
 
main "$@"