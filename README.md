# splunk_tape_backup

Back up Splunk cold buckets from `colddb` to a tape-mounted filesystem.

The main workflow is in `backup-to-tape.sh`. It copies bucket directories from:

- `SPLUNK_DB/<index>/colddb/<bucket>`

into:

- `BACKUP_ROOT/<index>/<bucket>`

The script keeps a local ledger so already archived buckets are skipped on later runs.

## Requirements

- Linux host with `bash`, `rsync`, `find`, `flock`, `mountpoint`, `df`, `stat`, `realpath`, and `mtx`
- A mounted tape filesystem such as LTFS or StoreOpen LTFS
- Read access to the Splunk bucket data
- Write access to the tape mount and local state/log directories
- In most environments, run as `root` so the script can mount media and access the tape changer

## Quick Start

### 1. Create local directories

Example:

```bash
sudo mkdir -p /tape_mount/splunk_backup
sudo mkdir -p /var/lib/splunk-coldb-backup
sudo mkdir -p /var/log/splunk-coldb-backup
```

### 2. Mount the tape to the backup directory

Use the mount command required by your tape stack. Example placeholder:

```bash
sudo ltfs /tape_mount/splunk_backup -o devname=/dev/nst0
```

If your environment uses a different LTFS or vendor mount command, substitute that instead.

Confirm the mount:

```bash
mountpoint /tape_mount/splunk_backup
```

### 3. Set the required environment

Example:

```bash
export SPLUNK_DB=/opt/splunk/var/lib/splunk
export BACKUP_ROOT=/tape_mount/splunk_backup
export STATE_DIR=/var/lib/splunk-coldb-backup
export LOG_DIR=/var/log/splunk-coldb-backup
export MTX_DEV=/dev/sch0
export TAPE_DRIVE=0
```

### 4. Run the backup

```bash
sudo -E bash ./backup-to-tape.sh
```

## Using Explicit Mount Commands

If you want the script to mount and unmount the tape automatically during rotation, set `MOUNT_CMD` and `UMOUNT_CMD`.

Example:

```bash
export MOUNT_CMD='ltfs /tape_mount/splunk_backup -o devname=/dev/nst0'
export UMOUNT_CMD='umount /tape_mount/splunk_backup'
sudo -E bash ./backup-to-tape.sh
```

If the tape is already mounted before each run, leave both variables unset and the script will treat them as no-ops.

## Dry Run

To test discovery and logging without copying data:

```bash
export DRY_RUN=1
sudo -E bash ./backup-to-tape.sh
```

## Test Harness

The repository includes a self-contained test harness that uses a mock `mtx` and a fake media mount:

```bash
bash tools/test-run.sh
```

Dry-run mode for the harness:

```bash
bash tools/test-run.sh --dry
```

## Common Variables

- `SPLUNK_DB`: Splunk index root on the indexer
- `BACKUP_ROOT`: mounted tape filesystem
- `STATE_DIR`: local ledger and catalog state
- `LOG_DIR`: log directory
- `MTX_DEV`: media changer device for `mtx`
- `TAPE_DRIVE`: tape drive index for `mtx`
- `VERIFY_METHOD`: `size` or `none`
- `MIN_FREE_BYTES`: safety buffer before tape rotation

## Notes

- The script copies both `db_*` and `rb_*` buckets by default.
- Recently rolled or recently modified buckets are skipped by default.
- Tape workflows are forced to serial execution even if `PARALLELISM` is set higher.