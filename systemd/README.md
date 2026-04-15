# systemd units for `backup-to-tape.sh`

This folder contains:

- `splunk-tape-backup.service`: one-shot backup job
- `splunk-tape-backup.timer`: schedule at 04:30 every day

## 1) Copy units into systemd

```bash
sudo cp systemd/splunk-tape-backup.service /etc/systemd/system/
sudo cp systemd/splunk-tape-backup.timer /etc/systemd/system/
```

## 2) Ensure script path is correct

The service expects the script at:

```bash
/opt/splunk_tape_backup/backup-to-tape.sh
```

If your path differs, edit `/etc/systemd/system/splunk-tape-backup.service` and update `ExecStart` and `WorkingDirectory`.

## 3) Optional environment overrides

Create `/etc/default/splunk-tape-backup` for runtime overrides:

```bash
LOG_LEVEL=info
DRY_RUN=0
SPLUNK_DB=/archdisk/splunk_db
BACKUP_ROOT=/tape_mount/splunk_backup
STATE_DIR=/var/lib/splunk-coldb-backup
CPU_NICE_LEVEL=10
IO_NICE_CLASS=2
IO_NICE_LEVEL=7
```

Priority is intentionally controlled by the script (`ensure_low_priority`) via
these environment variables. The systemd unit does not set `Nice=` or IO
scheduling values to avoid double-applying niceness when the script re-execs.

## 4) Enable and start timer

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now splunk-tape-backup.timer
```

## 5) Verify schedule and run manually

```bash
systemctl list-timers --all | grep splunk-tape-backup
sudo systemctl start splunk-tape-backup.service
sudo journalctl -u splunk-tape-backup.service -n 100 --no-pager
```
