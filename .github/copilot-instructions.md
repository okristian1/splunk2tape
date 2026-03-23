# Copilot instructions for splunk_tape_backup

## Project overview (single-script tool)
- Primary workflow lives in [backup-to-tape.sh](backup-to-tape.sh): it copies Splunk cold buckets from `$SPLUNK_DB/<index>/colddb` to a tape-mounted filesystem at `$BACKUP_ROOT/<index>`.
- Data flow: bucket dir → rsync to `$BACKUP_ROOT/<index>/.tmp/<bucket>.partial-*` → size verify → atomic `mv` into final bucket dir.
- Idempotency & resume: `$STATE_DIR/buckets_done.log` (ledger) prevents re-copy; per-run manifests are written on tape and mirrored to `$STATE_DIR/tape_manifests`.
- Tape integration targets an HPE MSL3040 library using `mtx` for load/unload; drive/slot ranges are configured via `MTX_DEV`, `TAPE_DRIVE`, `SLOT_FIRST`, `SLOT_LAST`.

## Key operational knobs (env vars)
- `SPLUNK_DB` and `BACKUP_ROOT` control source and tape mount paths.
- `MOUNT_CMD` / `UMOUNT_CMD` are used to mount the tape filesystem (e.g., LTFS). Defaults are no-ops; the script expects `$BACKUP_ROOT` to be a mountpoint.
- `VERIFY_METHOD=size|none` controls integrity checks (size compares total regular-file bytes via `stat`).
- `MIN_FREE_BYTES` and `SOFT_LIMIT_BYTES` control tape capacity behavior; soft limit forces serial mode.
- `PARALLELISM` defaults to 1 because tape is sequential; higher values are only sensible for VTL backends.
- `CPU_NICE_LEVEL`, `IO_NICE_CLASS`, `IO_NICE_LEVEL` lower process priority to protect a busy Splunk indexer.
- `SKIP_MOUNT_CHECK=1` bypasses the `mountpoint -q` check (for testing on plain directories).

## State and catalogs
- Ledger: `$STATE_DIR/buckets_done.log` (global “already archived” list).
- Catalog: `$STATE_DIR/catalog.csv` records `time,run_id,volume_tag,index,bucket,bytes,dst_path` for restores.
- Manifests: `.manifest_<RUN_ID>*.txt` written to tape root and mirrored locally.

## Conventions & patterns
- Tape rotation is automatic when free space (`df`) is below `bucket_bytes + MIN_FREE_BYTES`; the current tape is marked full in `$STATE_DIR/tapes_full.list`.
- Buckets are selected from `db_*` and/or `rb_*` based on `INCLUDE_DB`/`INCLUDE_RB` flags.
- The script uses `flock` on the ledger and catalog to remain safe across restarts.

## Where to look when modifying behavior
- Tape handling: `ensure_tape_ready()`, `rotate_tape()`, and `mtx` helpers in [backup-to-tape.sh](backup-to-tape.sh).
- Copy/verify semantics: `copy_bucket_atomic()` and `verify_copy()` in [backup-to-tape.sh](backup-to-tape.sh).
- Index discovery and bucket selection: `discover_indexes()` and `list_buckets_for_index()`.

## Testing without tape hardware
- `tools/test-run.sh` is a self-contained harness: creates fake Splunk indexes, mounts a tmpfs, wires the mock `mtx`, and runs the backup end-to-end.
- `tools/mtx-mock.sh` simulates an HPE MSL3040 changer (40 slots, WA0001L9–WA0040L9). State persists in `/tmp/mtx-mock.state`.
- Usage: `bash tools/test-run.sh` (full run), `--dry` (simulate), `--clean` (remove artifacts).
- The harness sets `MIN_FREE_BYTES=0` and uses tmpfs so `mountpoint -q` passes without `SKIP_MOUNT_CHECK`.

## Bash pitfalls to watch for
- `set -Eeuo pipefail` is active; `(( var++ ))` returns exit code 1 when var=0 — always append `|| true`.
- `log()` writes to stderr so that `$(func)` subshell captures are not polluted.
- `verify_copy()` uses `find -type f | stat --format='%s'` (not `du -sb`) to avoid directory-entry size differences across filesystems.
