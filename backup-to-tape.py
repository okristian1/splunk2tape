#!/usr/bin/env python3
"""Back up Splunk cold buckets to a tape-mounted filesystem.

Tape may change between runs; we avoid duplication using a durable local ledger.
Designed for environments where only ONE indexer can access tape.
Performs atomic copy (temp -> verify -> move), idempotent, and resumable across tapes.

Requires: Python 3.7+, rsync, mtx, df, mountpoint (external commands)
"""

import argparse
import csv
import fcntl
import logging
import os
import re
import shutil
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import List, Optional, Tuple

# ---------------------------------------------------------------------------
# Configuration (mirrors the bash env-var interface)
# ---------------------------------------------------------------------------

def env(name: str, default: str = "") -> str:
    return os.environ.get(name, default)


def env_int(name: str, default: int = 0) -> int:
    return int(os.environ.get(name, str(default)))


class Config:
    """All tunables, populated from environment variables."""

    def __init__(self) -> None:
        # Priority
        self.cpu_nice_level = env_int("CPU_NICE_LEVEL", 10)
        self.io_nice_class = env_int("IO_NICE_CLASS", 2)   # 2=best-effort
        self.io_nice_level = env_int("IO_NICE_LEVEL", 7)   # 0-7 (7=lowest)

        # Paths
        self.splunk_db = env("SPLUNK_DB", "/archdisk/splunk_db")
        self.backup_root = env("BACKUP_ROOT", "/tape_mount/splunk_backup")

        # Index selection
        self.indexes = env("INDEXES", "").split() if env("INDEXES") else []
        self.include_db = env("INCLUDE_DB", "1") == "1"
        self.include_rb = env("INCLUDE_RB", "1") == "1"

        # Logging / locking
        self.log_dir = env("LOG_DIR", "/var/log/splunk-coldb-backup")
        self.log_file = env("LOG_FILE", "") or os.path.join(self.log_dir, "run.log")
        self.lock_file = env("LOCK_FILE", "/var/lock/splunk_coldb_backup.lock")

        # Modes
        self.dry_run = env("DRY_RUN", "0") == "1"
        self.parallelism = env_int("PARALLELISM", 1)
        self.verify_method = env("VERIFY_METHOD", "size")  # "size" | "none"
        self.stop_on_copy_error = env("STOP_ON_COPY_ERROR", "1") == "1"

        # State
        self.state_dir = env("STATE_DIR", "/var/lib/splunk-coldb-backup")
        self.ledger_file = env("LEDGER_FILE", "") or os.path.join(self.state_dir, "buckets_done.log")
        self.tape_manifest_dir = env("TAPE_MANIFEST_DIR", "") or os.path.join(self.state_dir, "tape_manifests")
        self.run_id = env("RUN_ID", "") or datetime.now().strftime("%Y%m%d_%H%M%S")
        self.catalog_file = env("CATALOG_FILE", "") or os.path.join(self.state_dir, "catalog.csv")

        # Capacity
        self.soft_limit_bytes = env_int("SOFT_LIMIT_BYTES", 0)
        self.min_free_bytes = env_int("MIN_FREE_BYTES", 200_000_000_000)  # 200 GB

        # Force serial if soft limit is active
        if self.soft_limit_bytes > 0:
            self.parallelism = 1

        # Tape changer
        self.mtx_dev = env("MTX_DEV", "/dev/sch0")
        self.tape_drive = env_int("TAPE_DRIVE", 0)
        self.slot_first = env_int("SLOT_FIRST", 1)
        self.slot_last = env_int("SLOT_LAST", 40)

        # Mount / unmount commands
        self.mount_cmd = env("MOUNT_CMD", ":")
        self.umount_cmd = env("UMOUNT_CMD", ":")

        # Tape-full tracking
        self.tapes_full_list = env("TAPES_FULL_LIST", "") or os.path.join(self.state_dir, "tapes_full.list")

        # Mount check
        self.skip_mount_check = env("SKIP_MOUNT_CHECK", "0") == "1"

        # Derived (set later after tape is mounted)
        self.tape_manifest_on_tape: str = ""

    def init_tape_manifest_path(self, suffix: str = "") -> None:
        base = f".manifest_{self.run_id}{suffix}.txt"
        self.tape_manifest_on_tape = os.path.join(self.backup_root, base)


# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

logger = logging.getLogger("backup-to-tape")


def setup_logging(cfg: Config) -> None:
    os.makedirs(cfg.log_dir, exist_ok=True)

    fmt = logging.Formatter("[%(asctime)s] %(message)s", datefmt="%Y-%m-%d %H:%M:%S%z")

    # File handler
    fh = logging.FileHandler(cfg.log_file)
    fh.setFormatter(fmt)

    # Stderr handler
    sh = logging.StreamHandler(sys.stderr)
    sh.setFormatter(fmt)

    logger.addHandler(fh)
    logger.addHandler(sh)
    logger.setLevel(logging.DEBUG)


def log(msg: str) -> None:
    logger.info(msg)


def err(msg: str) -> None:
    logger.error("[ERROR] %s", msg)


# ---------------------------------------------------------------------------
# Utility helpers
# ---------------------------------------------------------------------------

def have_cmd(name: str) -> bool:
    return shutil.which(name) is not None


def human_bytes(n: int) -> str:
    """Return a human-readable size string (IEC units)."""
    for unit in ("B", "KiB", "MiB", "GiB", "TiB", "PiB"):
        if abs(n) < 1024:
            return f"{n:.1f} {unit}" if unit != "B" else f"{n} {unit}"
        n /= 1024  # type: ignore[assignment]
    return f"{n:.1f} EiB"


def run_cmd(cmd: str, check: bool = True) -> subprocess.CompletedProcess:
    """Run a shell command (string) and return the result."""
    return subprocess.run(cmd, shell=True, capture_output=True, text=True, check=check)


def run_cmd_stdout(cmd: str) -> str:
    """Run a shell command and return stripped stdout."""
    r = run_cmd(cmd)
    return r.stdout.strip()


def timestamp() -> str:
    return datetime.now().strftime("%Y-%m-%d %H:%M:%S%z")


# ---------------------------------------------------------------------------
# Low-priority execution
# ---------------------------------------------------------------------------

def ensure_low_priority(cfg: Config) -> None:
    """Re-exec under nice/ionice if not already done."""
    if os.environ.get("LOW_PRIORITY_APPLIED"):
        return
    os.environ["LOW_PRIORITY_APPLIED"] = "1"

    new_argv: List[str] = []
    if have_cmd("nice"):
        if have_cmd("ionice"):
            new_argv = [
                "ionice", "-c", str(cfg.io_nice_class),
                "-n", str(cfg.io_nice_level),
                "nice", "-n", str(cfg.cpu_nice_level),
            ]
        else:
            new_argv = ["nice", "-n", str(cfg.cpu_nice_level)]

    if new_argv:
        new_argv += [sys.executable] + sys.argv
        os.execvp(new_argv[0], new_argv)


# ---------------------------------------------------------------------------
# Locking
# ---------------------------------------------------------------------------

_lock_fd: Optional[int] = None


def acquire_lock(cfg: Config) -> None:
    global _lock_fd
    _lock_fd = os.open(cfg.lock_file, os.O_WRONLY | os.O_CREAT, 0o600)
    try:
        fcntl.flock(_lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        err(f"Another backup is already running (lock: {cfg.lock_file}). Exiting.")
        sys.exit(1)


# ---------------------------------------------------------------------------
# Mount check
# ---------------------------------------------------------------------------

def ensure_mount(cfg: Config) -> None:
    if cfg.skip_mount_check:
        return
    r = subprocess.run(["mountpoint", "-q", cfg.backup_root], capture_output=True)
    if r.returncode != 0:
        err(f"Backup root {cfg.backup_root} is not a mountpoint. Tape/library not mounted? Aborting.")
        sys.exit(3)


# ---------------------------------------------------------------------------
# Index / bucket discovery
# ---------------------------------------------------------------------------

def discover_indexes(cfg: Config) -> List[str]:
    if cfg.indexes:
        return sorted(cfg.indexes)

    result: List[str] = []
    try:
        for entry in sorted(os.listdir(cfg.splunk_db)):
            idx_dir = os.path.join(cfg.splunk_db, entry)
            if os.path.isdir(idx_dir) and os.path.isdir(os.path.join(idx_dir, "colddb")):
                result.append(entry)
    except FileNotFoundError:
        pass
    return result


def list_buckets_for_index(cfg: Config, idx: str) -> List[str]:
    src = os.path.join(cfg.splunk_db, idx, "colddb")
    if not os.path.isdir(src):
        return []

    prefixes: List[str] = []
    if cfg.include_db:
        prefixes.append("db_")
    if cfg.include_rb:
        prefixes.append("rb_")
    if not prefixes:
        return []

    result: List[str] = []
    try:
        for entry in sorted(os.listdir(src)):
            full = os.path.join(src, entry)
            if os.path.isdir(full) and any(entry.startswith(p) for p in prefixes):
                result.append(full)
    except FileNotFoundError:
        pass
    return result


# ---------------------------------------------------------------------------
# Required commands
# ---------------------------------------------------------------------------

REQUIRED_CMDS = ["find", "rsync", "du", "flock", "date", "mkdir", "mv", "awk", "mountpoint", "df", "mtx"]


def require_cmds() -> None:
    missing = [c for c in REQUIRED_CMDS if not have_cmd(c)]
    if missing:
        for c in missing:
            err(f"Missing required command: {c}")
        err("Install required commands and re-run.")
        sys.exit(1)


# ---------------------------------------------------------------------------
# Tape changer helpers (mtx wrappers)
# ---------------------------------------------------------------------------

def tape_status(cfg: Config) -> str:
    r = run_cmd(f"mtx -f {cfg.mtx_dev} status")
    return r.stdout


def get_loaded_tape_tag(cfg: Config) -> str:
    """Return VolumeTag of the currently loaded tape, or '' if none."""
    output = tape_status(cfg)
    pattern = rf"Data Transfer Element {cfg.tape_drive}:.*VolumeTag=(\S+)"
    m = re.search(pattern, output)
    return m.group(1) if m else ""


def get_loaded_from_slot(cfg: Config) -> str:
    """Return the slot number from which the current tape was loaded (or '')."""
    output = tape_status(cfg)
    pattern = rf"Data Transfer Element {cfg.tape_drive}:.*Storage Element (\d+) Loaded"
    m = re.search(pattern, output)
    return m.group(1) if m else ""


def slot_is_full(cfg: Config, slot: int) -> bool:
    output = tape_status(cfg)
    for line in output.splitlines():
        if f"Storage Element {slot}:" in line and "Full" in line:
            return True
    return False


def slot_volumetag(cfg: Config, slot: int) -> str:
    output = tape_status(cfg)
    for line in output.splitlines():
        if f"Storage Element {slot}:" in line:
            m = re.search(r"VolumeTag=(\S+)", line)
            if m:
                return m.group(1)
    return ""


# ---------------------------------------------------------------------------
# Tape full tracking
# ---------------------------------------------------------------------------

def tape_mark_full(cfg: Config, tag: str) -> None:
    os.makedirs(cfg.state_dir, exist_ok=True)
    Path(cfg.tapes_full_list).touch()
    existing = _read_lines(cfg.tapes_full_list)
    if tag not in existing:
        with open(cfg.tapes_full_list, "a") as f:
            f.write(tag + "\n")


def tape_is_marked_full(cfg: Config, tag: str) -> bool:
    if not os.path.isfile(cfg.tapes_full_list):
        return False
    return tag in _read_lines(cfg.tapes_full_list)


def _read_lines(path: str) -> set:
    try:
        with open(path) as f:
            return {line.strip() for line in f if line.strip()}
    except FileNotFoundError:
        return set()


# ---------------------------------------------------------------------------
# Tape slot selection
# ---------------------------------------------------------------------------

def find_next_tape_slot(cfg: Config) -> Optional[Tuple[int, str]]:
    """Return (slot, volumetag) for the next usable tape, or None."""
    for s in range(cfg.slot_first, cfg.slot_last + 1):
        if slot_is_full(cfg, s):
            tag = slot_volumetag(cfg, s)
            if tag and not tape_is_marked_full(cfg, tag):
                return (s, tag)
    return None


# ---------------------------------------------------------------------------
# Tape load / unload / mount
# ---------------------------------------------------------------------------

def load_tape_from_slot(cfg: Config, slot: int) -> None:
    log(f"Loading tape from slot {slot} into drive {cfg.tape_drive} ...")
    run_cmd(f"mtx -f {cfg.mtx_dev} load {slot} {cfg.tape_drive}")


def unload_tape_to_slot(cfg: Config, slot: int) -> None:
    log(f"Unloading tape from drive {cfg.tape_drive} back to slot {slot} ...")
    run_cmd(f"mtx -f {cfg.mtx_dev} unload {slot} {cfg.tape_drive}")


def ensure_tape_ready(cfg: Config) -> str:
    """Make sure a tape is loaded and mounted. Returns VolumeTag."""
    tag = get_loaded_tape_tag(cfg)
    if not tag:
        nxt = find_next_tape_slot(cfg)
        if nxt is None:
            err(f"No available (non-full) tapes found in slots {cfg.slot_first}-{cfg.slot_last}.")
            sys.exit(10)
        slot, ntag = nxt
        load_tape_from_slot(cfg, slot)
        run_cmd(cfg.mount_cmd, check=False)
        ensure_mount(cfg)
        tag = ntag
    # Verify the mountpoint even if a tape was already loaded
    ensure_mount(cfg)
    return tag


# ---------------------------------------------------------------------------
# Capacity
# ---------------------------------------------------------------------------

def tape_free_bytes(cfg: Config) -> int:
    """Available bytes on the mounted tape filesystem."""
    output = run_cmd_stdout(f"df -B1 --output=avail {cfg.backup_root} | tail -n 1")
    return int(output.strip())


# ---------------------------------------------------------------------------
# Tape rotation
# ---------------------------------------------------------------------------

def rotate_tape(cfg: Config, curtag: str) -> None:
    curslot = get_loaded_from_slot(cfg)

    log(f"Rotating tape. Marking current tape as FULL: {curtag}")
    tape_mark_full(cfg, curtag)

    log(f"Finalizing tape manifest for {curtag}")
    try:
        with open(cfg.tape_manifest_on_tape, "a") as f:
            f.write(f"# EndOfTape VolumeTag={curtag} Time={timestamp()} Run={cfg.run_id}\n")
    except OSError:
        pass
    _mirror_manifest(cfg)

    run_cmd(cfg.umount_cmd, check=False)

    if curslot:
        unload_tape_to_slot(cfg, int(curslot))
    else:
        err("Could not determine original slot for loaded tape. Please unload manually.")
        sys.exit(11)

    nxt = find_next_tape_slot(cfg)
    if nxt is None:
        err(f"No remaining tapes available after marking {curtag} full.")
        sys.exit(12)
    slot, ntag = nxt

    load_tape_from_slot(cfg, slot)
    run_cmd(cfg.mount_cmd, check=False)
    ensure_mount(cfg)

    # Start a new manifest on the new tape
    cfg.tape_manifest_on_tape = os.path.join(
        cfg.backup_root, f".manifest_{cfg.run_id}_{ntag}.txt"
    )
    try:
        Path(cfg.tape_manifest_on_tape).touch()
    except OSError:
        err(f"Cannot write manifest on new tape: {cfg.tape_manifest_on_tape}")
        sys.exit(13)

    log(f"Tape rotated. Now using VolumeTag={ntag}")


# ---------------------------------------------------------------------------
# Ledger & manifests
# ---------------------------------------------------------------------------

def already_in_ledger(cfg: Config, rel: str) -> bool:
    return rel in _read_lines(cfg.ledger_file)


def mark_ledger(cfg: Config, rel: str) -> None:
    os.makedirs(os.path.dirname(cfg.ledger_file), exist_ok=True)
    with open(cfg.ledger_file, "a") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        f.write(rel + "\n")
        fcntl.flock(f, fcntl.LOCK_UN)


def append_to_tape_manifest(cfg: Config, rel: str) -> None:
    os.makedirs(cfg.tape_manifest_dir, exist_ok=True)
    with open(cfg.tape_manifest_on_tape, "a") as f:
        f.write(rel + "\n")
    _mirror_manifest(cfg)


def _mirror_manifest(cfg: Config) -> None:
    """Copy tape manifest to local mirror directory."""
    os.makedirs(cfg.tape_manifest_dir, exist_ok=True)
    base = os.path.basename(cfg.tape_manifest_on_tape)
    try:
        shutil.copy2(cfg.tape_manifest_on_tape, os.path.join(cfg.tape_manifest_dir, base))
    except OSError:
        pass


# ---------------------------------------------------------------------------
# Catalog
# ---------------------------------------------------------------------------

def init_catalog(cfg: Config) -> None:
    os.makedirs(cfg.state_dir, exist_ok=True)
    if not os.path.isfile(cfg.catalog_file):
        with open(cfg.catalog_file, "w", newline="") as f:
            f.write("time,run_id,volume_tag,index,bucket,bytes,dst_path\n")


def catalog_add(cfg: Config, vol: str, idx: str, bucket: str,
                nbytes: int, dst: str) -> None:
    line = f"{datetime.now(timezone.utc).isoformat()},{cfg.run_id},{vol},{idx},{bucket},{nbytes},{dst}"
    with open(cfg.catalog_file, "a") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        f.write(line + "\n")
        fcntl.flock(f, fcntl.LOCK_UN)


# ---------------------------------------------------------------------------
# Copy & verify
# ---------------------------------------------------------------------------

def _total_file_bytes(path: str) -> int:
    """Sum of sizes of all regular files under *path* (not counting dir entries)."""
    total = 0
    for root, _dirs, files in os.walk(path):
        for fname in files:
            fpath = os.path.join(root, fname)
            try:
                total += os.path.getsize(fpath)
            except OSError:
                pass
    return total


def verify_copy(src: str, dst: str, method: str) -> bool:
    if method == "none":
        return True
    if method == "size":
        s = _total_file_bytes(src)
        d = _total_file_bytes(dst)
        if s != d:
            err(f"Size mismatch: src={s} dst={d}")
            return False
        return True
    err(f"Unknown VERIFY_METHOD={method}")
    return False


def bucket_size(path: str) -> int:
    """Total disk usage of a bucket directory (like du -sb)."""
    total = 0
    for root, dirs, files in os.walk(path):
        total += os.path.getsize(root)
        for name in files:
            fp = os.path.join(root, name)
            try:
                total += os.path.getsize(fp)
            except OSError:
                pass
    return total


def copy_bucket_atomic(cfg: Config, src_bucket: str, dst_index_dir: str) -> bool:
    """Atomically copy a bucket to the tape filesystem.

    Returns True on success, False on failure.
    """
    bucket_name = os.path.basename(src_bucket)
    final_dst = os.path.join(dst_index_dir, bucket_name)
    tmp_dir = os.path.join(dst_index_dir, ".tmp", f"{bucket_name}.partial-{os.getpid()}")

    # Already exists on tape — skip
    if os.path.isdir(final_dst):
        log(f"Skip (exists on tape): {final_dst}")
        return True

    os.makedirs(os.path.join(dst_index_dir, ".tmp"), exist_ok=True)

    if cfg.dry_run:
        log(f"[DRY-RUN] Would copy: {src_bucket} -> {final_dst}")
        return True

    # ---- Real copy ----
    r = subprocess.run(
        ["rsync", "-aH", "--numeric-ids", "--delete-delay",
         src_bucket + "/", tmp_dir + "/"],
        capture_output=True, text=True,
    )
    if r.returncode != 0:
        err(f"rsync failed for {src_bucket}: {r.stderr.strip()}")
        shutil.rmtree(tmp_dir, ignore_errors=True)
        return False

    if verify_copy(src_bucket, tmp_dir, cfg.verify_method):
        os.rename(tmp_dir, final_dst)
        log(f"Backed up: {src_bucket} -> {final_dst}")
        return True
    else:
        err(f"Verification failed: {src_bucket} (temp at {tmp_dir}). Cleaning up.")
        shutil.rmtree(tmp_dir, ignore_errors=True)
        return False


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    cfg = Config()

    ensure_low_priority(cfg)
    require_cmds()
    setup_logging(cfg)
    acquire_lock(cfg)

    # Prepare state directories
    for d in [cfg.state_dir, cfg.tape_manifest_dir, cfg.backup_root]:
        os.makedirs(d, exist_ok=True)
    Path(cfg.ledger_file).touch()

    log("=== Splunk cold bucket backup started ===")
    log(f"SPLUNK_DB={cfg.splunk_db} BACKUP_ROOT={cfg.backup_root} "
        f"INCLUDE_DB={cfg.include_db} INCLUDE_RB={cfg.include_rb} "
        f"DRY_RUN={cfg.dry_run} VERIFY={cfg.verify_method} RUN_ID={cfg.run_id}")
    log(f"STATE_DIR={cfg.state_dir} LEDGER_FILE={cfg.ledger_file} "
        f"SOFT_LIMIT_BYTES={cfg.soft_limit_bytes} PARALLELISM={cfg.parallelism}")

    init_catalog(cfg)
    Path(cfg.tapes_full_list).touch()

    current_tape_tag = ensure_tape_ready(cfg)
    log(f"Current tape VolumeTag={current_tape_tag}")

    # Initialize manifest path now that tape is mounted
    cfg.init_tape_manifest_path()
    Path(cfg.tape_manifest_on_tape).touch()

    indexes = discover_indexes(cfg)
    if not indexes:
        err(f"No indexes with colddb found under {cfg.splunk_db}")
        sys.exit(1)

    total = 0
    skipped = 0
    copied = 0
    failed = 0
    current_bytes = 0
    stop_early = False

    for idx in indexes:
        if stop_early:
            break

        dst_idx_dir = os.path.join(cfg.backup_root, idx)
        os.makedirs(os.path.join(dst_idx_dir, ".tmp"), exist_ok=True)

        log(f"--- Index: {idx} ---")

        buckets = list_buckets_for_index(cfg, idx)
        if not buckets:
            log(f"No matching buckets in {cfg.splunk_db}/{idx}/colddb")
            continue

        for b in buckets:
            if stop_early:
                break

            total += 1
            bucket_name = os.path.basename(b)
            rel = f"{idx}/{bucket_name}"
            final_dst = os.path.join(dst_idx_dir, bucket_name)

            # Ledger-based dedupe across tapes/runs
            if already_in_ledger(cfg, rel):
                skipped += 1
                log(f"Skip (ledger): {rel} already archived")
                continue

            # Already present on the currently-mounted tape
            if os.path.isdir(final_dst):
                skipped += 1
                log(f"Skip (exists on tape): {final_dst}")
                mark_ledger(cfg, rel)
                append_to_tape_manifest(cfg, rel)
                continue

            # Bucket size (for capacity checks and catalog)
            b_bytes = bucket_size(b)

            # Ensure tape is loaded/mounted; refresh tag
            current_tape_tag = ensure_tape_ready(cfg)

            free = tape_free_bytes(cfg)

            # If not enough space (including safety buffer), rotate
            if free < b_bytes + cfg.min_free_bytes:
                log(f"Not enough space on tape VolumeTag={current_tape_tag}. "
                    f"Free={human_bytes(free)}, need={human_bytes(b_bytes)} "
                    f"+ buffer={human_bytes(cfg.min_free_bytes)}. Rotating...")
                rotate_tape(cfg, current_tape_tag)
                current_tape_tag = ensure_tape_ready(cfg)
                free = tape_free_bytes(cfg)

            # Soft limit
            if cfg.soft_limit_bytes > 0 and current_bytes + b_bytes > cfg.soft_limit_bytes:
                log(f"Soft tape limit reached at {human_bytes(current_bytes)}; "
                    f"next bucket {rel} ({human_bytes(b_bytes)}) would exceed limit "
                    f"{human_bytes(cfg.soft_limit_bytes)}.")
                log("Stopping run cleanly for tape rotation. Re-run after mounting next tape.")
                stop_early = True
                break

            # Serial copy (recommended for tape)
            if copy_bucket_atomic(cfg, b, dst_idx_dir):
                copied += 1
                mark_ledger(cfg, rel)
                append_to_tape_manifest(cfg, rel)
                catalog_add(cfg, current_tape_tag, idx, bucket_name, b_bytes, final_dst)
                current_bytes += b_bytes
            else:
                failed += 1
                err(f"Copy failed: {rel}")
                if cfg.stop_on_copy_error:
                    err("STOP_ON_COPY_ERROR=1 → stopping early (tape full or I/O error?).")
                    stop_early = True
                    break

    # --- Summary ---
    log("=== Summary ===")
    log(f"Total buckets seen: {total}")
    log(f"Already present or ledger-skipped: {skipped}")
    log(f"Copied this run: {copied}")
    log(f"Failed: {failed}")
    if cfg.soft_limit_bytes > 0:
        log(f"Bytes written this run (approx): {human_bytes(current_bytes)} / "
            f"{human_bytes(cfg.soft_limit_bytes)}")
    log(f"Run manifest written to: {cfg.tape_manifest_on_tape}")
    log(f"Local manifest mirror: {cfg.tape_manifest_dir}/{os.path.basename(cfg.tape_manifest_on_tape)}")
    log(f"Ledger file: {cfg.ledger_file}")
    log("=== Done ===")

    if failed > 0:
        sys.exit(2)


if __name__ == "__main__":
    main()
