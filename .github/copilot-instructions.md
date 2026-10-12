# Copilot instructions for splunk_tape_backup

## Project overview (single-script tool)
- Primary workflow lives in [backup-to-tape.sh](../backup-to-tape.sh): it copies Splunk cold buckets from `$SPLUNK_DB/<index>/colddb` to a tape-mounted filesystem at `$BACKUP_ROOT/<index>`.
- Data flow: bucket dir → rsync to `$BACKUP_ROOT/<index>/.tmp/<bucket>.partial-*` → size verify → atomic `mv` into final bucket dir.
- Idempotency & resume: `$STATE_DIR/buckets_done.log` (ledger) prevents re-copy; per-run manifests are written on tape and mirrored to `$STATE_DIR/tape_manifests`.
- Tape integration targets an HPE MSL3040 library using `mtx` for load/unload; drive/slot ranges are configured via `MTX_DEV`, `TAPE_DRIVE`, `SLOT_FIRST`, `SLOT_LAST`.

## Key operational knobs (env vars)
- `SPLUNK_DB` defaults to `/archdisk/splunk_db`; `BACKUP_ROOT` controls the tape mount path.
- `MOUNT_CMD` / `UMOUNT_CMD` override tape filesystem mount handling. The script unmounts before rotation and exit; a failed unmount must never be followed by `mtx unload`.
- `VERIFY_METHOD=sha256|size|none` controls integrity checks. SHA-256 is the default and reads copied file contents through LTFS; `size` is faster but only checks byte totals.
- `MIN_FREE_BYTES` and `SOFT_LIMIT_BYTES` control tape capacity behavior.
- `CPU_NICE_LEVEL`, `IO_NICE_CLASS`, `IO_NICE_LEVEL` lower process priority to protect a busy Splunk indexer.
- `SKIP_MOUNT_CHECK=1` bypasses the `mountpoint -q` check (for testing on plain directories).

## State and catalogs
- Ledger: `$STATE_DIR/buckets_done.log` (global “already archived” list).
- Catalog: `$STATE_DIR/catalog.csv` records `time,run_id,volume_tag,index,bucket,bytes,dst_path` for restores.
- Manifests: `.manifest_<RUN_ID>*.txt` written to tape root and mirrored locally.

## Conventions & patterns
- Tape rotation is automatic when free space (`df`) is below `bucket_bytes + MIN_FREE_BYTES`; the current tape is marked full in `$STATE_DIR/tapes_full.list`.
- Buckets are selected from `db_*` and/or `rb_*` based on `INCLUDE_DB`/`INCLUDE_RB` flags.
- Only `colddb` buckets are considered; sibling `frozendb` or other database paths are ignored.
- The script uses `flock` on the ledger and catalog to remain safe across restarts.

## Where to look when modifying behavior
- Tape handling: `ensure_tape_ready()`, `rotate_tape()`, and `mtx` helpers in [backup-to-tape.sh](../backup-to-tape.sh).
- Copy/verify semantics: `copy_bucket_atomic()` and `verify_copy()` in [backup-to-tape.sh](../backup-to-tape.sh).
- Index discovery and bucket selection: `discover_indexes()` and `list_buckets_for_index()`.

## Testing without tape hardware
- `tools/test-run.sh` is a self-contained harness: creates fake Splunk indexes, mounts a tmpfs, wires the mock `mtx`, and runs the backup end-to-end. Needs root (bind mounts).
- `tools/smoke-test.sh` is a non-root, non-hardware test: same mocks plus `SKIP_MOUNT_CHECK=1` and marker-backed mount commands; it covers SHA-256 corruption, identity rejection, unmount failure, metadata recovery, rotation, and prior failure paths. GNU-isms are shimmed only when the system lacks them.
- `systemd/splunk-tape-backup.service` uses the script shell as MainPID, `KillMode=mixed`, and no automatic timeout/SIGKILL escalation so Bash can cleanly unmount LTFS.
- `tools/mtx-mock.sh` simulates an HPE MSL3040 changer (40 slots, WA0001L9–WA0040L9). State persists in `/tmp/mtx-mock.state`. Opt-in test hooks: `MTX_MOCK_FAIL_LOAD=all|<slot>`, `MTX_MOCK_OMIT_DRIVE_TAG=1`.
- Usage: `bash tools/test-run.sh` (full run), `--dry` (simulate), `--clean` (remove artifacts).
- The harness sets `MIN_FREE_BYTES=0` and uses tmpfs so `mountpoint -q` passes without `SKIP_MOUNT_CHECK`.

## Bash pitfalls to watch for
- `set -Eeuo pipefail` is active; `(( var++ ))` returns exit code 1 when var=0 — always append `|| true`.
- A function called inside an `if` condition runs with errexit disabled, even with `set -E`: always check commands whose failure matters (the final `mv`, `mtx load`, mount) explicitly and return a specific exit code/reason.
- `log()` writes to stderr so that `$(func)` subshell captures are not polluted; `mtx load` output is redirected to stderr the same way because its progress goes to stdout and would otherwise contaminate the captured VolumeTag.
- `LAST_KNOWN_TAPE_TAG` set inside `$(ensure_tape_ready)` does not persist to the parent shell; `sync_known_tape_tag()` in the parent keeps it current.
- `verify_copy()` uses `find -type f | stat --format='%s'` (not `du -sb`) to avoid directory-entry size differences across filesystems.
- mtx reports a present cartridge as `Full` (occupied), not "capacity exhausted"; do not read more into that word than presence.
