# splunk_tape_backup

Back up Splunk cold buckets from `colddb` to a tape-mounted filesystem.

The main workflow is in `backup-to-tape.sh`. It copies bucket directories from:

- `SPLUNK_DB/<index>/colddb/<bucket>`

into:

- `BACKUP_ROOT/<index>/<bucket>`

The script keeps a local ledger so already archived buckets are skipped on later runs.

## Requirements

- Linux host with `bash`, `rsync`, `find`, `flock`, `mountpoint`, `df`, `stat`, `realpath`, and `mtx`
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

You can mount the tape yourself before the run, or let the script mount it automatically.

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

By default, the script mounts with `ltfs "$BACKUP_ROOT" -o devname="$LTFS_DEVNAME"` and unmounts with `umount "$BACKUP_ROOT"`.

Set `MOUNT_CMD` and `UMOUNT_CMD` only if your environment needs a different workflow.

Example:

```bash
export MOUNT_CMD='ltfs /tape_mount/splunk_backup -o devname=/dev/nst0'
export UMOUNT_CMD='umount /tape_mount/splunk_backup'
sudo -E bash ./backup-to-tape.sh
```

If you leave both variables unset, the script can still rotate tapes automatically using the default LTFS mount and `umount` commands.

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
- `LTFS_DEVNAME`: tape device used by the default `ltfs` mount command
- `MOUNT_CMD`: optional explicit mount command override
- `UMOUNT_CMD`: optional explicit unmount command override
- `VERIFY_METHOD`: `size` or `none`
- `MIN_FREE_BYTES`: safety buffer before tape rotation

## Notes

- The script only scans `colddb` under each index. It ignores sibling paths such as `frozendb`, `hotdb`, `warmdb`, and `thaweddb`.
- The script copies both `db_*` and `rb_*` buckets by default.
- Recently rolled or recently modified buckets are skipped by default.
- Tape workflows are forced to serial execution even if `PARALLELISM` is set higher.