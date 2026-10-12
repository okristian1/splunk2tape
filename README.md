# splunk_tape_backup

Back up Splunk cold buckets from `colddb` to a tape-mounted filesystem.

The main workflow is in `backup-to-tape.sh`. It copies bucket directories from:

- `SPLUNK_DB/<index>/colddb/<bucket>`

into:

- `BACKUP_ROOT/<index>/<bucket>`

The script keeps a local ledger so already archived buckets are skipped on later runs.

## Requirements

- Linux host with `bash`, `rsync`, `find`, `flock`, `mountpoint`, `df`, `stat`, `realpath`, and `mtx`
- SHA-256 support (`sha256sum` or `shasum`), `cmp`, `mktemp`, and NUL-aware `sort` for the default integrity mode
- LTFS or another tape filesystem stack that can mount the loaded tape
- Read access to the Splunk bucket data
- Write access to the tape mount and local state/log directories
- In most environments, run as `root` so the script can mount media and access the tape changer
- Default automatic mount behavior uses `ltfs` with `LTFS_DEVNAME=/dev/nst0`

## Quick Start

### 1. Create local directories

Example:

```bash
sudo mkdir -p /tape_mount/splunk_backup
sudo mkdir -p /var/lib/splunk-coldb-backup
sudo mkdir -p /var/log/splunk-coldb-backup
```

### 2. Mount the tape to the backup directory

You can mount the tape yourself before the run, or let the script mount it automatically. The script unmounts `BACKUP_ROOT` before exiting, including when it was mounted manually, so LTFS can flush metadata before systemd tears down the service.

Manual example:

```bash
sudo ltfs /tape_mount/splunk_backup -o devname=/dev/nst0
```

If your environment uses a different LTFS or vendor mount command, substitute that instead.

Confirm the mount:

```bash
mountpoint /tape_mount/splunk_backup
```

### 3. Set the required environment

For common defaults, no exports are required. The script will:

- use `SPLUNK_DB=/archdisk/splunk_db`
- use `BACKUP_ROOT=/tape_mount/splunk_backup`
- use `MTX_DEV=/dev/sch0` and `TAPE_DRIVE=0`
- use `ltfs` with `LTFS_DEVNAME=/dev/nst0` when it needs to mount media during rotation

If your environment differs, override the variables you need. Example:

```bash
export SPLUNK_DB=/opt/splunk/var/lib/splunk
export BACKUP_ROOT=/tape_mount/splunk_backup
export STATE_DIR=/var/lib/splunk-coldb-backup
export LOG_DIR=/var/log/splunk-coldb-backup
export MTX_DEV=/dev/sch0
export TAPE_DRIVE=0
export LTFS_DEVNAME=/dev/nst0
```

### 4. Run the backup

```bash
sudo bash ./backup-to-tape.sh
```

If you set any overrides first, preserve them when invoking the script:

```bash
sudo -E bash ./backup-to-tape.sh
```

## Using Explicit Mount Commands

By default, the script mounts with `ltfs "$BACKUP_ROOT" -o devname="$LTFS_DEVNAME"` and unmounts with `umount "$BACKUP_ROOT"`. Rotation stops without unloading the cartridge if unmount fails.

Set `MOUNT_CMD` and `UMOUNT_CMD` only if your environment needs a different workflow.

Example:

```bash
export MOUNT_CMD='ltfs /tape_mount/splunk_backup -o devname=/dev/nst0'
export UMOUNT_CMD='umount /tape_mount/splunk_backup'
sudo -E bash ./backup-to-tape.sh
```

If you leave both variables unset, the script can still rotate tapes automatically using the default LTFS mount and `umount` commands. A failed final unmount makes the run fail with exit code 17.

## Integrity Verification

`VERIFY_METHOD=sha256` is the default. After each copy, the script hashes every regular file on the source and reads/hashes the copied files through the mounted tape filesystem before committing the bucket. This adds a readback pass over copied data and can substantially increase run time; because checks happen per bucket, the drive may also seek/backhitch between writes and reads. Set `VERIFY_METHOD=size` for the faster size-only check, or `none` to rely only on rsync's transfer checks.

SHA-256 readback verifies the bytes exposed by LTFS, but LTFS or the operating-system cache may satisfy reads without a physical reread from tape. A true media readback requires a separate later read/restore pass. Retain the tape manifest and perform periodic restore tests for critical data.

## Dry Run

To test discovery and logging without copying data:

```bash
export DRY_RUN=1
sudo -E bash ./backup-to-tape.sh
```

## Test Harness

### Root end-to-end harness

The repository includes a self-contained test harness that uses a mock `mtx` and a real bind-mounted fake media directory (needs root):

```bash
bash tools/test-run.sh
```

Dry-run mode for the harness:

```bash
bash tools/test-run.sh --dry
```

### Non-root smoke test

A lighter smoke test needs no root, no bind mounts, and no tape hardware. It runs the script against the `mtx`/`df` mocks with `SKIP_MOUNT_CHECK=1`; it covers SHA-256 mismatch, unknown tape identity, unmount failures, metadata recovery, rotation, and existing copy/load/mount failures. Lock contention is tested only when real `flock` is available.

```bash
bash tools/smoke-test.sh
```

It is portable across macOS and Linux: GNU-specific tools (`stat --format`, `find -printf`/`-regextype`, `date -Is`, `flock`, `mountpoint`, `realpath -m`) are shimmed only when the system does not already provide them, so on a GNU system nothing is shimmed. On macOS the shims need `gstat` (Homebrew coreutils) and `python3`.

## Common Variables

- `SPLUNK_DB`: Splunk index root on the indexer
- `BACKUP_ROOT`: mounted tape filesystem
- `STATE_DIR`: local ledger and catalog state
- `LOG_DIR`: log directory
- `MTX_DEV`: media changer device for `mtx`
- `TAPE_DRIVE`: tape drive index for `mtx`
- `LTFS_DEVNAME`: tape device used by the default `ltfs` mount command
- `MOUNT_CMD`: optional explicit mount command override
- `UMOUNT_CMD`: optional explicit unmount command override
- `VERIFY_METHOD`: `sha256` (default, full content readback), `size` (fast metadata check), or `none`
- `MIN_FREE_BYTES`: safety buffer before tape rotation
- `RUN_UNTIL_DRAINED`: `1` = repeat copy passes until no eligible buckets remain (default)
- `MAX_DRAIN_PASSES`: safety cap on drain passes when `RUN_UNTIL_DRAINED=1` (0 = unlimited)
- `STRICT_COMPLETION`: `1` = fail the run if eligible buckets still remain after the final pass

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | Lock conflict, missing required commands, path-safety check failed, or no indexes with colddb found |
| 2 | One or more bucket copies failed |
| 3 | Mount failed (mount command error or mountpoint check failed) |
| 4 | Could not create the run manifest on the initial tape |
| 6 | `STRICT_COMPLETION=1` and eligible buckets remain after the final pass |
| 10 | No available non-cleaning data tape found in the configured slot range |
| 11 | Loaded tape slot could not be determined, cannot unload back |
| 12 | No remaining tapes after rotation |
| 13 | Could not create the manifest on the newly rotated tape |
| 14 | A cleaning cartridge is loaded in the drive |
| 15 | Loaded tape VolumeTag does not match `DATA_TAPE_TAG_REGEX` |
| 16 | `mtx load` of the selected tape failed |
| 17 | LTFS unmount failed; the cartridge was not unloaded |
| 18 | Could not append the end-of-tape marker; the cartridge was not unloaded |
| 19 | Loaded tape identity could not be verified |
| 20 | Local manifest mirror could not be synchronized |
| 21 | Loaded tape barcode did not match the selected slot |

## Notes

- The script only scans `colddb` under each index. It ignores sibling paths such as `frozendb`, `hotdb`, `warmdb`, and `thaweddb`.
- The script copies both `db_*` and `rb_*` buckets by default.
- Recently rolled or recently modified buckets are skipped by default.
- Tape workflows are serial only; the script does not support parallel copy workers.
- The script removes stale `.tmp/*.partial-*` directories from the currently mounted tape before starting new copies.
- Buckets deferred by the activity guards are re-checked in later drain passes, so a run keeps going until the queue is empty (or `MAX_DRAIN_PASSES` is reached).
- The local ledger (`STATE_DIR/buckets_done.log`) is the only dedupe across tapes: if it is lost, already archived buckets may be copied again onto a new tape. Keep `STATE_DIR` (ledger, catalog, manifest mirrors) safe and back it up.
- The systemd unit has no automatic start or stop timeout and disables `SIGKILL` escalation to protect in-progress tape writes and LTFS metadata updates. A stuck run or unmount needs operator intervention; do not use `kill -9` or force a reboot while LTFS is active.
- A loaded tape with no usable volume identity is rejected rather than written without a catalogable tag.