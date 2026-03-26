#!/usr/bin/env bash
# test-run.sh — End-to-end test of backup-to-tape.sh on a RHEL 9 VM
#                without physical tape hardware.
#
# What it does:
#   1. Creates fake Splunk index dirs with small colddb buckets
#   2. Puts mtx-mock.sh first in PATH
#   3. Resets mock tape changer state
#   4. Sets all env vars to test-friendly values
#   5. Runs backup-to-tape.sh
#   6. Shows results (catalog, ledger, tape contents)
#
# Usage (as root, or with sudo):
#   bash tools/test-run.sh          # full run with actual copies
#   bash tools/test-run.sh --dry    # dry-run mode (no copies)
#   bash tools/test-run.sh --clean  # remove test artifacts and exit
#
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# --- Test layout ---
TEST_ROOT="/tmp/splunk-tape-test"
FAKE_SPLUNK_DB="$TEST_ROOT/splunk_db"
FAKE_TAPE_MOUNT="$TEST_ROOT/tape_mount"
FAKE_MEDIA_ROOT="$TEST_ROOT/media"
FAKE_STATE_DIR="$TEST_ROOT/state"
FAKE_LOG_DIR="$TEST_ROOT/logs"
FAKE_LOCK="/tmp/splunk_tape_test.lock"

# ---------------------------------------------------------------------------
cleanup() {
  echo "==> Cleaning up test artifacts under $TEST_ROOT ..."
  # Unmount any bind mount if still mounted
  if mountpoint -q "$FAKE_TAPE_MOUNT" 2>/dev/null; then
    sudo umount "$FAKE_TAPE_MOUNT" || true
  fi
  rm -rf "$TEST_ROOT"
  rm -f "$FAKE_LOCK"
  rm -f /tmp/mtx-mock.state
  echo "    Done."
}

create_bucket() {
  local bucket_dir="$1"
  local block_count="$2"

  mkdir -p "$bucket_dir"
  dd if=/dev/urandom of="$bucket_dir/rawdata.dat" bs=4096 count="$block_count" status=none 2>/dev/null
  echo "bucket metadata" > "$bucket_dir/.metadata"
  find "$bucket_dir" -exec touch -d '2 hours ago' {} +
  touch -d '2 hours ago' "$bucket_dir"
}

run_backup() {
  bash "$REPO_DIR/backup-to-tape.sh"
}

if [[ "${1:-}" == "--clean" ]]; then
  cleanup
  exit 0
fi

# ---------------------------------------------------------------------------
# 1. Clean previous run
cleanup 2>/dev/null || true

# 2. Create fake Splunk indexes with small colddb buckets
echo "==> Creating fake Splunk cold buckets ..."
for idx in main security syslog; do
  colddb="$FAKE_SPLUNK_DB/$idx/colddb"
  warmdb="$FAKE_SPLUNK_DB/$idx/warmdb"
  hotdb="$FAKE_SPLUNK_DB/$idx/hotdb"
  frozendb="$FAKE_SPLUNK_DB/$idx/frozendb"
  thaweddb="$FAKE_SPLUNK_DB/$idx/thaweddb"

  mkdir -p "$warmdb" "$hotdb" "$frozendb" "$thaweddb"
  echo "warm bucket placeholder" > "$warmdb/db_warm_${idx}.dat"
  echo "hot bucket placeholder" > "$hotdb/db_hot_${idx}.dat"
  echo "frozen bucket placeholder" > "$frozendb/db_frozen_${idx}.dat"
  echo "thawed bucket placeholder" > "$thaweddb/db_thawed_${idx}.dat"

  for i in 1 2 3; do
    bdir="$colddb/db_1707000000_1706900000_${i}_GUID-$(uuidgen 2>/dev/null || echo "aaaa-bbbb-$i")"
    create_bucket "$bdir" 10
  done
  # One rb_ bucket per index to exercise INCLUDE_RB
  rbdir="$colddb/rb_1707000000_1706900000_0_GUID-$(uuidgen 2>/dev/null || echo "cccc-dddd")"
  create_bucket "$rbdir" 5

  if [[ "$idx" == "main" ]]; then
    recent_bucket="$colddb/db_1707100000_1707000000_recent_GUID-$(uuidgen 2>/dev/null || echo "recent-guid")"
    mkdir -p "$recent_bucket"
    dd if=/dev/urandom of="$recent_bucket/rawdata.dat" bs=4096 count=4 status=none 2>/dev/null
    echo "recent bucket metadata" > "$recent_bucket/.metadata"

    touched_bucket="$colddb/db_1707200000_1707100000_touch_GUID-$(uuidgen 2>/dev/null || echo "touch-guid")"
    mkdir -p "$touched_bucket"
    dd if=/dev/urandom of="$touched_bucket/rawdata.dat" bs=4096 count=4 status=none 2>/dev/null
    echo "touched bucket metadata" > "$touched_bucket/.metadata"
    find "$touched_bucket" -exec touch -d '2 hours ago' {} +
    touch -d '2 hours ago' "$touched_bucket"
    touch -d '2 minutes ago' "$touched_bucket/rawdata.dat"
  fi
done

echo "    Created indexes: main, security, syslog"
find "$FAKE_SPLUNK_DB" -name colddb -type d | while read -r d; do
  echo "    $(basename "$(dirname "$d")"): $(ls "$d" | wc -l) buckets"
done

# 3. Create simulated per-tape media and mount root
mkdir -p "$FAKE_TAPE_MOUNT" "$FAKE_MEDIA_ROOT" "$FAKE_STATE_DIR" "$FAKE_LOG_DIR"
mkdir -p "$FAKE_MEDIA_ROOT/WA0001L9" "$FAKE_MEDIA_ROOT/WA0003L9"
printf '%s\n' 90000 > "$FAKE_MEDIA_ROOT/WA0001L9/.capacity_bytes"
printf '%s\n' 600000 > "$FAKE_MEDIA_ROOT/WA0003L9/.capacity_bytes"
echo "==> Simulating media capacities: WA0001L9=90000 bytes, WA0003L9=600000 bytes"
echo "==> Simulating slot 2 as a cleaning cartridge"

# 4. Reset mock mtx state so slot 1 gets loaded first
rm -f /tmp/mtx-mock.state

# 5. Put mock mtx first in PATH
export PATH="$SCRIPT_DIR:$PATH"
# Ensure the mock is executable and linked as "mtx" in tools/
if [[ ! -x "$SCRIPT_DIR/mtx" ]]; then
  ln -sf "$SCRIPT_DIR/mtx-mock.sh" "$SCRIPT_DIR/mtx"
  chmod +x "$SCRIPT_DIR/mtx"
fi
chmod +x "$SCRIPT_DIR/df" "$SCRIPT_DIR/test-media-mount.sh" "$SCRIPT_DIR/mtx-mock.sh" "$SCRIPT_DIR/test-run.sh"

echo "==> Using mock mtx: $(command -v mtx)"
echo "==> Using mocked df: $(command -v df)"

# 6. Set env vars for the backup script
export SPLUNK_DB="$FAKE_SPLUNK_DB"
export BACKUP_ROOT="$FAKE_TAPE_MOUNT"
export TEST_MEDIA_ROOT="$FAKE_MEDIA_ROOT"
export STATE_DIR="$FAKE_STATE_DIR"
export LOG_DIR="$FAKE_LOG_DIR"
export LOG_FILE="$FAKE_LOG_DIR/run.log"
export LOCK_FILE="$FAKE_LOCK"
export RUN_ID="${RUN_ID:-testrun_$(date +%Y%m%d_%H%M%S)}"
initial_run_id="$RUN_ID"
rerun_run_id=""
export MTX_DEV="/dev/null"
export MOUNT_CMD="bash $SCRIPT_DIR/test-media-mount.sh mount"
export UMOUNT_CMD="bash $SCRIPT_DIR/test-media-mount.sh umount"
export CLEANING_SLOTS=2
export DATA_TAPE_TAG_REGEX='^WA[0-9]+L9$'
export MIN_FREE_BYTES=0              # no safety buffer needed for test
export SOFT_LIMIT_BYTES=0
export INCLUDE_DB=1
export INCLUDE_RB=1
export VERIFY_METHOD=size
export STOP_ON_COPY_ERROR=1
export BUCKET_MIN_DIR_AGE_SECONDS=1800
export BUCKET_MIN_QUIET_SECONDS=900

if [[ "${1:-}" == "--dry" ]]; then
  export DRY_RUN=1
  echo "==> DRY-RUN mode enabled (no actual copies)"
else
  export DRY_RUN=0
fi

stale_partial="$FAKE_MEDIA_ROOT/WA0001L9/main/.tmp/db_stale.partial-9999"
mkdir -p "$stale_partial"
echo "orphaned temp data" > "$stale_partial/orphan.dat"
find "$stale_partial" -exec touch -d '2 hours ago' {} +
touch -d '2 hours ago' "$stale_partial"

# 7. Run the backup
echo ""
echo "================================================================"
echo "  Running backup-to-tape.sh"
echo "================================================================"
echo ""
if run_backup; then
  rc=0
else
  rc=$?
fi

rerun_rc=0
incremental_bucket=""
if [[ "$DRY_RUN" != "1" && $rc -eq 0 ]]; then
  incremental_bucket="$FAKE_SPLUNK_DB/security/colddb/db_1707300000_1707200000_new_GUID-$(uuidgen 2>/dev/null || echo "new-guid")"
  create_bucket "$incremental_bucket" 6
  export RUN_ID="${RUN_ID}_rerun"
  rerun_run_id="$RUN_ID"

  echo ""
  echo "================================================================"
  echo "  Running incremental rerun"
  echo "================================================================"
  echo ""
  if run_backup; then
    rerun_rc=0
  else
    rerun_rc=$?
  fi
fi

# 8. Assertions for cleaning-cartridge filtering and rotation
echo ""
echo "================================================================"
echo "  Assertions"
echo "================================================================"
echo ""

assert_failed=0
if grep -q "Skip slot 2: cleaning cartridge" "$FAKE_LOG_DIR/run.log"; then
  echo "PASS: cleaning cartridge in slot 2 was skipped"
else
  echo "FAIL: cleaning cartridge skip was not observed in log"
  assert_failed=1
fi

if grep -q "Rotating tape\. Marking current tape as FULL: WA0001L9" "$FAKE_LOG_DIR/run.log"; then
  echo "PASS: first tape was rotated when capacity was exhausted"
else
  echo "FAIL: tape rotation did not occur"
  assert_failed=1
fi

if grep -q "Skip (active): main/db_1707100000_1707000000_recent_.*recently rolled" "$FAKE_LOG_DIR/run.log"; then
  echo "PASS: recently rolled bucket was skipped"
else
  echo "FAIL: recently rolled bucket was not skipped"
  assert_failed=1
fi

if grep -q "Skip (active): main/db_1707200000_1707100000_touch_.*recently touched" "$FAKE_LOG_DIR/run.log"; then
  echo "PASS: recently touched bucket was skipped"
else
  echo "FAIL: recently touched bucket was not skipped"
  assert_failed=1
fi

if grep -q "Tape rotated\. Now using VolumeTag=WA0003L9" "$FAKE_LOG_DIR/run.log"; then
  echo "PASS: rotation selected the next non-cleaning data tape"
else
  echo "FAIL: next data tape was not selected after rotation"
  assert_failed=1
fi

if [[ -d "$FAKE_MEDIA_ROOT/WA0001L9" && -d "$FAKE_MEDIA_ROOT/WA0003L9" ]] \
  && find "$FAKE_MEDIA_ROOT/WA0001L9" -mindepth 1 | grep -q . \
  && find "$FAKE_MEDIA_ROOT/WA0003L9" -mindepth 1 | grep -q .; then
  echo "PASS: data was written across multiple simulated tapes"
else
  echo "FAIL: expected data on both simulated data tapes"
  assert_failed=1
fi

manifest_tape1="$FAKE_MEDIA_ROOT/WA0001L9/.manifest_${initial_run_id}.txt"
manifest_tape2="$FAKE_MEDIA_ROOT/WA0003L9/.manifest_${initial_run_id}_WA0003L9.txt"
rerun_manifest="$FAKE_MEDIA_ROOT/WA0003L9/.manifest_${rerun_run_id}.txt"
if [[ -f "$manifest_tape1" && -f "$manifest_tape2" ]]; then
  echo "PASS: per-tape manifests exist on both simulated tapes"
else
  echo "FAIL: expected manifests on both simulated tapes"
  echo "      missing? tape1=$( [[ -f "$manifest_tape1" ]] && echo no || echo yes ) tape2=$( [[ -f "$manifest_tape2" ]] && echo no || echo yes )"
  assert_failed=1
fi

if [[ "$DRY_RUN" != "1" ]]; then
  if [[ -f "$rerun_manifest" ]]; then
    echo "PASS: rerun manifest exists on the currently loaded tape"
  else
    echo "FAIL: rerun manifest is missing from the currently loaded tape"
    assert_failed=1
  fi
fi

if find "$FAKE_MEDIA_ROOT" \( -name warmdb -o -name hotdb -o -name frozendb -o -name thaweddb -o -name 'db_warm_*' -o -name 'db_hot_*' -o -name 'db_frozen_*' -o -name 'db_thawed_*' \) | grep -q .; then
  echo "FAIL: non-cold Splunk data was copied to simulated tapes"
  assert_failed=1
else
  echo "PASS: warmdb/hotdb/frozendb/thaweddb content was not backed up"
fi

if find "$FAKE_MEDIA_ROOT" \( -name 'db_1707100000_1707000000_recent_*' -o -name 'db_1707200000_1707100000_touch_*' \) | grep -q .; then
  echo "FAIL: active buckets were copied despite age/quiet filters"
  assert_failed=1
else
  echo "PASS: recently rolled and recently touched buckets were not copied"
fi

if grep -Eq 'main/db_1707100000_1707000000_recent_|main/db_1707200000_1707100000_touch_' "$FAKE_STATE_DIR/buckets_done.log" 2>/dev/null; then
  echo "FAIL: active buckets were recorded in the ledger"
  assert_failed=1
else
  echo "PASS: active buckets were not added to the ledger"
fi

if [[ ! -d "$FAKE_MEDIA_ROOT/WA0001L9/main/.tmp/db_stale.partial-9999" ]]; then
  echo "PASS: stale partial directory was cleaned before copy"
else
  echo "FAIL: stale partial directory was not cleaned"
  assert_failed=1
fi

if [[ "$DRY_RUN" != "1" ]]; then
  if [[ $rerun_rc -eq 0 ]]; then
    echo "PASS: incremental rerun completed successfully"
  else
    echo "FAIL: incremental rerun exited with code $rerun_rc"
    assert_failed=1
  fi

  if grep -q "Skip (ledger):" "$FAKE_LOG_DIR/run.log"; then
    echo "PASS: rerun reused the ledger to skip previously archived buckets"
  else
    echo "FAIL: rerun did not log any ledger-based skips"
    assert_failed=1
  fi

  if [[ -n "$incremental_bucket" ]] \
    && grep -Fq "security/$(basename "$incremental_bucket")" "$FAKE_STATE_DIR/buckets_done.log" 2>/dev/null; then
    echo "PASS: rerun archived the new bucket and recorded it in the ledger"
  else
    echo "FAIL: rerun did not archive the new bucket"
    assert_failed=1
  fi
fi

# 9. Show results
echo ""
echo "================================================================"
echo "  Test Results"
echo "================================================================"
echo ""

echo "--- Exit code: $rc ---"
echo ""

echo "--- Log (last 30 lines) ---"
tail -30 "$FAKE_LOG_DIR/run.log" 2>/dev/null || echo "(no log)"
echo ""

echo "--- Ledger (buckets_done.log) ---"
cat "$FAKE_STATE_DIR/buckets_done.log" 2>/dev/null || echo "(empty)"
echo ""

echo "--- Catalog (catalog.csv) ---"
cat "$FAKE_STATE_DIR/catalog.csv" 2>/dev/null || echo "(empty)"
echo ""

echo "--- Simulated tape contents ($FAKE_MEDIA_ROOT) ---"
find "$FAKE_MEDIA_ROOT" -mindepth 1 -maxdepth 3 \( -type d -o -type f \) 2>/dev/null | sort | head -120 || echo "(empty)"
echo ""

echo "--- Per-tape manifests ---"
for manifest in "$manifest_tape1" "$manifest_tape2" "$rerun_manifest"; do
  [[ -n "$manifest" ]] || continue
  if [[ -f "$manifest" ]]; then
    echo "[$manifest]"
    sed -n '1,40p' "$manifest"
  else
    echo "[$manifest] missing"
  fi
  echo ""
done
echo ""

echo "--- Mock tape changer state ---"
cat /tmp/mtx-mock.state 2>/dev/null || echo "(no state)"
echo ""

echo "Done. To clean up: bash tools/test-run.sh --clean"

if (( rc == 0 && rerun_rc == 0 && assert_failed == 0 )); then
  exit 0
fi
exit 1
