#!/usr/bin/env bash
# Back up Splunk cold buckets to a tape-mounted filesystem.
# Tape may change between runs; we avoid duplication using a durable local ledger.
# Designed for environments where only ONE indexer can access tape.
# Performs atomic copy (temp -> verify -> move), idempotent, and resumable across tapes.
#
# Requires: bash, find, rsync, du, flock, date, mkdir, mv, awk, cut, mountpoint
# Optional: numfmt (for pretty sizes)
 
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
    if have_cmd ionice; then
      exec ionice -c "$IO_NICE_CLASS" -n "$IO_NICE_LEVEL" nice -n "$CPU_NICE_LEVEL" "$0" "$@"
    else
      exec nice -n "$CPU_NICE_LEVEL" "$0" "$@"
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
LOCK_FILE="${LOCK_FILE:-/var/lock/splunk_coldb_backup.lock}"
 
# Dry run (1 = simulate, do not copy)
DRY_RUN="${DRY_RUN:-0}"
 
# Parallel copies (for tape, keep 1 unless your VTL backend benefits from concurrency)
PARALLELISM="${PARALLELISM:-1}"
 
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
 
# If soft limit is enabled, force serial copies to keep accounting precise
if (( SOFT_LIMIT_BYTES > 0 )); then
  PARALLELISM=1
fi

# The tape workflow is stateful and sequential. Keep execution serial until
# parallel job bookkeeping and stop semantics are redesigned.
if (( PARALLELISM > 1 )); then
  PARALLELISM=1
fi


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
 
timestamp() { date +"%Y-%m-%d %H:%M:%S%z"; }
log()       { echo "[$(timestamp)] $*" | tee -a "$LOG_FILE" >&2; }
err()       { echo "[$(timestamp)] [ERROR] $*" | tee -a "$LOG_FILE" >&2; }
 
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
  exec 200>"$LOCK_FILE"
  if ! flock -n 200; then
    err "Another backup is already running (lock: $LOCK_FILE). Exiting."
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

bucket_newest_mtime_epoch() {
  local bucket="$1"

  find "$bucket" -printf '%T@\n' 2>/dev/null \
    | awk 'BEGIN{max=0} {v=int($1); if (v>max) max=v} END{print max+0}'
}

bucket_skip_reason() {
  local bucket="$1"
  local now dir_mtime newest_mtime dir_age quiet_age

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
    newest_mtime="$(bucket_newest_mtime_epoch "$bucket")"
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

  (( missing == 0 )) || { err "Install required commands and re-run."; exit 1; }
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
  tape_status | grep -E "^Data Transfer Element ${TAPE_DRIVE}:" | head -n 1
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
  local tag
  tag="$(get_loaded_tape_tag || true)"
  if loaded_tape_is_cleaning; then
    err "Loaded media in drive $TAPE_DRIVE is a cleaning cartridge. Refusing to use it for backups."
    exit 14
  fi
  if [[ -n "$tag" ]] && ! slot_has_allowed_tag "$tag"; then
    err "Loaded media VolumeTag=$tag does not match DATA_TAPE_TAG_REGEX. Refusing to use it for backups."
    exit 15
  fi
  if [[ -z "$tag" ]]; then
    local next
    if ! next="$(find_next_tape_slot)"; then
      err "No available non-cleaning data tapes found in slots $SLOT_FIRST-$SLOT_LAST."
      exit 10
    fi
    local slot="${next%%:*}"
    local ntag="${next##*:}"
    load_tape_from_slot "$slot"
    # mount if needed
    mount_tape_filesystem
    ensure_mount
    tag="$ntag"
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
 
# Rotate tape: mark current as full, unmount, unload, load next, mount
rotate_tape() {
  local curtag="$1"
  local curslot
  curslot="$(get_loaded_from_slot || true)"
 
  log "Rotating tape. Marking current tape as FULL: $curtag"
  tape_mark_full "$curtag"
 
  log "Finalizing tape manifest for $curtag"
  echo "# EndOfTape VolumeTag=$curtag Time=$(timestamp) Run=$RUN_ID" >> "$TAPE_MANIFEST_ON_TAPE" || true
  cp -f "$TAPE_MANIFEST_ON_TAPE" "$TAPE_MANIFEST_DIR/$(basename "$TAPE_MANIFEST_ON_TAPE")" || true
 
  unmount_tape_filesystem || true
 
  # If we know the original slot, unload back to it; otherwise try the next empty slot strategy (not shown)
  if [[ -n "$curslot" ]]; then
    unload_tape_to_slot "$curslot"
  else
    err "Could not determine original slot for loaded tape. Please unload manually."
    exit 11
  fi
 
  local next
  if ! next="$(find_next_tape_slot)"; then
    err "No remaining tapes available after marking $curtag full."
    exit 12
  fi
  local slot="${next%%:*}"
  local ntag="${next##*:}"
 
  load_tape_from_slot "$slot"
  mount_tape_filesystem
  ensure_mount
 
  # Start a new manifest on the new tape (new RUN_ID optional; keeping same RUN_ID is fine)
  TAPE_MANIFEST_ON_TAPE="$BACKUP_ROOT/.manifest_${RUN_ID}_${ntag}.txt"
  : > "$TAPE_MANIFEST_ON_TAPE" || { err "Cannot write manifest on new tape: $TAPE_MANIFEST_ON_TAPE"; exit 13; }
  record_manifest_path "$TAPE_MANIFEST_ON_TAPE"
 
  log "Tape rotated. Now using VolumeTag=$ntag"
}
 
# --- Ledger & Manifests ---
 
already_in_ledger() {
  local rel="$1"  # format: index/bucketname
  [[ -f "$LEDGER_FILE" ]] && grep -Fxq -- "$rel" "$LEDGER_FILE"
}
 
mark_ledger() {
  local rel="$1"
  mkdir -p "$(dirname "$LEDGER_FILE")"
  { flock -x 9; echo "$rel" >> "$LEDGER_FILE"; } 9>>"$LEDGER_FILE"
}
 
append_to_tape_manifest() {
  local rel="$1"
  mkdir -p "$TAPE_MANIFEST_DIR"
  echo "$rel" >> "$TAPE_MANIFEST_ON_TAPE"
  # Mirror locally (use the same filename as on tape)
  cp -f "$TAPE_MANIFEST_ON_TAPE" "$TAPE_MANIFEST_DIR/$(basename "$TAPE_MANIFEST_ON_TAPE")" || true
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
 
verify_copy() {
  local src="$1"
  local dst="$2"
  case "$VERIFY_METHOD" in
    size)
      # Compare total size of regular files only (avoids filesystem-dependent
      # directory entry sizes differing between e.g. ext4 and tmpfs/LTFS)
      local s d
      s=$(regular_file_bytes "$src")
      d=$(regular_file_bytes "$dst")
      if [[ "$s" != "$d" ]]; then
        err "Size mismatch: src=$s dst=$d"
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
  rsync "${rsync_args[@]}" \
    -- "$src_bucket"/ "$tmp_dir"/
  # ---------------------------------------------------
 
  if verify_copy "$src_bucket" "$tmp_dir"; then
    mv -- "$tmp_dir" "$final_dst"
    log "Backed up: $src_bucket -> $final_dst"
  else
    err "Verification failed: $src_bucket (temp at $tmp_dir). Cleaning up."
    cleanup_tmp_dir "$tmp_dir" || true
    return 1
  fi
}
 
main() {
  ensure_low_priority "$@"
  require_cmds
  mkdir -p "$LOG_DIR"
  touch "$LOG_FILE"
 
  acquire_lock
  mkdir -p "$BACKUP_ROOT"
  if [[ "$DRY_RUN" != "1" ]]; then
    mkdir -p "$STATE_DIR" "$TAPE_MANIFEST_DIR"
    touch "$LEDGER_FILE"
  fi
 
  log "=== Splunk cold bucket backup started ==="
  log "SPLUNK_DB=$SPLUNK_DB BACKUP_ROOT=$BACKUP_ROOT INCLUDE_DB=$INCLUDE_DB INCLUDE_RB=$INCLUDE_RB DRY_RUN=$DRY_RUN VERIFY=$VERIFY_METHOD RUN_ID=$RUN_ID"
  log "STATE_DIR=$STATE_DIR LEDGER_FILE=$LEDGER_FILE SOFT_LIMIT_BYTES=$SOFT_LIMIT_BYTES PARALLELISM=$PARALLELISM"
  log "BUCKET_MIN_DIR_AGE_SECONDS=$BUCKET_MIN_DIR_AGE_SECONDS BUCKET_MIN_QUIET_SECONDS=$BUCKET_MIN_QUIET_SECONDS"
  log "RSYNC_BWLIMIT_MBIT=$RSYNC_BWLIMIT_MBIT"
 
  local current_tape_tag
  if [[ "$DRY_RUN" == "1" ]]; then
    current_tape_tag="$(get_loaded_tape_tag || true)"
    current_tape_tag="${current_tape_tag:-DRY-RUN}"
    log "DRY_RUN=1: skipping tape load/rotation and state mutations"
  else
    init_catalog
    touch "$TAPES_FULL_LIST"
    current_tape_tag="$(ensure_tape_ready)"
    # Create or touch this run's manifest on the tape (after mount)
    : > "$TAPE_MANIFEST_ON_TAPE" || { err "Cannot write manifest on tape: $TAPE_MANIFEST_ON_TAPE"; exit 4; }
    record_manifest_path "$TAPE_MANIFEST_ON_TAPE"
  fi
  log "Current tape VolumeTag=$current_tape_tag"
 
  local indexes
  mapfile -t indexes < <(discover_indexes)
  if (( ${#indexes[@]} == 0 )); then
    err "No indexes with colddb found under $SPLUNK_DB"
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
      bucket_name=$(basename "$b")
      local rel="$idx/$bucket_name"
      local final_dst="$dst_idx_dir/$bucket_name"
 
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
      if skip_reason="$(bucket_skip_reason "$b")"; then
        (( skipped_active++ )) || true
        log "Skip (active): $rel $skip_reason"
        continue
      fi
 
      # Calculate bucket size once (used for free-space checks and catalog)
      local bucket_bytes
      bucket_bytes=$(regular_file_bytes "$b")

      if [[ "$DRY_RUN" != "1" ]]; then
        # Make sure tape is loaded/mounted; refresh tag (in case of rotation)
        current_tape_tag="$(ensure_tape_ready)"

        local free_bytes
        free_bytes="$(tape_free_bytes)"

        # If not enough space (including safety buffer), rotate
        if (( free_bytes < bucket_bytes + MIN_FREE_BYTES )); then
          log "Not enough space on tape VolumeTag=$current_tape_tag. Free=$(human_bytes "$free_bytes"), need=$(human_bytes "$bucket_bytes") + buffer=$(human_bytes "$MIN_FREE_BYTES"). Rotating..."
          rotate_tape "$current_tape_tag"
          current_tape_tag="$(ensure_tape_ready)"
        fi

        # Capacity-aware batching (soft limit)
        if (( SOFT_LIMIT_BYTES > 0 )) && (( current_bytes + bucket_bytes > SOFT_LIMIT_BYTES )); then
          log "Soft tape limit reached at $(human_bytes "$current_bytes"); next bucket $rel ($(human_bytes "$bucket_bytes")) would exceed limit $(human_bytes "$SOFT_LIMIT_BYTES")."
          log "Stopping run cleanly for tape rotation. Re-run after mounting next tape."
          break 2  # Leave both loops
        fi
      fi
 
      # Serial mode only; tape workflows depend on ordered state transitions.
      if copy_bucket_atomic "$b" "$dst_idx_dir"; then
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
          err "STOP_ON_COPY_ERROR=1 → stopping early (tape full or I/O error?)."
          break 2
        fi
      fi
    done
  done
 
  # Wait for any background copies to finish (if used)
  wait || true
 
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
  log "Ledger file: $LEDGER_FILE"
  log "=== Done ==="
 
  (( failed == 0 )) || exit 2
}
 
main "$@"