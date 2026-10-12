#!/usr/bin/env bash
# Non-root smoke test for backup-to-tape.sh (no bind mounts, no sudo).
# Uses the repo's mtx/df mocks, SKIP_MOUNT_CHECK=1 and a marker-backed mount mock.
#
# Portable across macOS and Linux: for the GNU tools the script (and the df
# mock) rely on (stat --format, find -regextype/-printf, date -Is, flock,
# mountpoint, realpath -m) it writes shims into a temp bin dir that is
# prepended to PATH -- but ONLY when the system tool does not already provide
# the GNU behaviour, so on a GNU system (e.g. RHEL) nothing is shimmed. The
# shims themselves need gstat (for stat) and python3 (for find/realpath/sort).
#
# Scenarios:
#   RUN 1  full run with forced tape rotation (happy path)
#   RUN 2  incremental rerun (ledger dedupe)
#   RUN 3  cleaning cartridge in drive               -> exit 14
#   RUN 4  disallowed VolumeTag in drive             -> exit 15
#   RUN 5  dry run
#   RUN 6  final rename fails (dst exists as file)   -> exit 2, nothing recorded
#   RUN 7  mtx load fails                            -> exit 16 (tape_load_failed)
#   RUN 8  mount command fails                       -> exit 3 (mount_failed)
#   RUN 9  drive status lacks VolumeTag -> last-known-tag fallback after rotation
#   RUN 10 loaded tape identity unavailable           -> exit 19 before mount
#   RUN 11 unmount failure                            -> exit 17 without unload
#   RUN 12 missing ledger entry repaired idempotently
#   RUN 13 same-size corruption rejected by SHA-256
#   RUN 14 umount command succeeds but leaves mount present -> exit 17
#   RUN 15 concurrent run rejected by in-process flock -> exit 1
#   RUN 16 wrong barcode after load rejected before mount -> exit 21
#
# Usage: bash tools/smoke-test.sh
set -uo pipefail

# --- locate the repo root (follow symlinks so a symlink to this file works) ---
src="${BASH_SOURCE[0]}"
while [[ -L "$src" ]]; do
  dir="$(cd "$(dirname "$src")" && pwd)"
  src="$(readlink "$src")"
  [[ "$src" == /* ]] || src="$dir/$src"
done
REPO="$(cd "$(dirname "$src")/.." && pwd)"

[[ -f "$REPO/backup-to-tape.sh" ]] || { echo "ERROR: $REPO/backup-to-tape.sh not found" >&2; exit 2; }
command -v rsync >/dev/null 2>&1 || { echo "ERROR: rsync is required to run this test" >&2; exit 2; }
if command -v flock >/dev/null 2>&1; then REAL_FLOCK_AVAILABLE=1; else REAL_FLOCK_AVAILABLE=0; fi

T="$(mktemp -d /tmp/splunk-tape-smoke.XXXXXX)"
FAIL=0

assert() { # assert <desc> <cmd...>
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then echo "PASS: $desc"; else echo "FAIL: $desc"; FAIL=1; fi
}

rsync() {
  command rsync "$@"
  local result=$?
  [[ "$result" == "0" && "${TEST_CORRUPT_AFTER_RSYNC:-0}" == "1" ]] || return "$result"
  local target
  target="$(find "$BACKUP_ROOT" -type f -path "$BACKUP_ROOT/*/.tmp/*.partial-*/*" -print -quit)"
  [[ -n "$target" ]] || return 1
  printf '\001' | dd of="$target" bs=1 seek=0 conv=notrunc 2>/dev/null
}
export -f rsync

cleanup() {
  rm -f "${TEST_MOUNT_MARKER:-}"
  if command -v mountpoint >/dev/null 2>&1 && mountpoint -q "$T/backup_root" 2>/dev/null; then umount "$T/backup_root" || true; fi
  rm -rf "$T"
}
trap cleanup EXIT

# --- fake splunk db: 2 indexes, 2 old db buckets + 1 rb bucket each, 1 recent (active) ---
DB="$T/splunk_db"; BR="$T/backup_root"; MEDIA="$T/media"
ST="$T/state"; LD_="$T/logs"
mkdir -p "$DB" "$BR" "$MEDIA" "$ST" "$LD_"

backdate_dir() { # backdate_dir <dir>: set mtimes of all entries (and dir) to 3h ago, portably
  local d="$1" t f
  t="$(date -v-3H +%Y%m%d%H%M 2>/dev/null || date -d '3 hours ago' +%Y%m%d%H%M)"
  while IFS= read -r -d '' f; do
    touch -t "$t" -- "$f"
  done < <(find "$d" -print0)
  touch -t "$t" -- "$d"
}

mk_bucket() { # mk_bucket <dir> <kb>
  mkdir -p "$1"
  dd if=/dev/urandom of="$1/rawdata.dat" bs=1024 count="$2" status=none 2>/dev/null
  echo meta > "$1/.metadata"
  backdate_dir "$1"
}

mk_full_fixture() {
  # Same shape as RUN 1: 2 indexes x 3 old buckets + 1 recent (active).
  rm -rf "$DB" "$BR" "$MEDIA" "$ST"
  mkdir -p "$DB" "$BR" "$MEDIA" "$ST"
  rm -f "$MTX_MOCK_STATE"
  : > "$LD_/run.log"
  for idx in main security; do
    c="$DB/$idx/colddb"; mkdir -p "$c"
    mk_bucket "$c/db_1_2_a" 8
    mk_bucket "$c/db_1_2_b" 8
    mk_bucket "$c/rb_1_2_x" 4
  done
  recent="$DB/main/colddb/db_9_9_recent"
  mkdir -p "$recent"; echo x > "$recent/f"; find "$recent" -exec touch {} +
}

for idx in main security; do
  c="$DB/$idx/colddb"; mkdir -p "$c"
  mk_bucket "$c/db_1_2_a" 8
  mk_bucket "$c/db_1_2_b" 8
  mk_bucket "$c/rb_1_2_x" 4
done
# active bucket (recent) in main
recent="$DB/main/colddb/db_9_9_recent"
mkdir -p "$recent"; echo x > "$recent/f"; find "$recent" -exec touch {} +

# media: tape1 prefilled to capacity (forces rotation), tape2 big, slot2 cleaning
mkdir -p "$MEDIA/WA0001L9" "$MEDIA/WA0003L9"
printf 10000 > "$MEDIA/WA0001L9/.capacity_bytes"
dd if=/dev/zero of="$MEDIA/WA0001L9/prefill.dat" bs=10000 count=1 status=none 2>/dev/null
printf 600000 > "$MEDIA/WA0003L9/.capacity_bytes"

export MTX_MOCK_STATE="$T/mtx.state"
# Copy the mocks into a temp bin dir (keeps the repo tree clean)
mkdir -p "$T/bin"
cp "$REPO/tools/mtx-mock.sh" "$T/bin/mtx"
cp "$REPO/tools/df" "$T/bin/df"
chmod +x "$T/bin/mtx" "$T/bin/df"

# --- compatibility shims (only for what the system does not already provide) ---
# The backup script and the df mock need GNU-isms that BSD/macOS lacks. On a
# GNU system every probe below passes and no shim is written.

if ! stat --format='%s' / >/dev/null 2>&1; then
  cat > "$T/bin/stat" <<'SH'
#!/bin/bash
# GNU stat (BSD stat lacks --format/--printf); needs coreutils gstat.
for c in /opt/homebrew/bin/gstat /usr/local/bin/gstat /opt/local/bin/gstat; do
  if [[ -x "$c" ]]; then exec "$c" "$@"; fi
done
if command -v gstat >/dev/null 2>&1; then exec gstat "$@"; fi
echo "stat shim: gstat (GNU stat) not found" >&2
exit 127
SH
fi

if ! date -Is >/dev/null 2>&1; then
  cat > "$T/bin/date" <<'SH'
#!/bin/bash
# Translate GNU-only `date -Is`; pass everything else through to BSD date.
args=()
for a in "$@"; do
  if [[ "$a" == "-Is" ]]; then args+=(-Iseconds); else args+=("$a"); fi
done
exec /bin/date "${args[@]}"
SH
fi

if ! find "$T" -maxdepth 0 -printf '%p\n' >/dev/null 2>&1 \
   || ! find "$T" -maxdepth 0 -regextype posix-extended -regex '.+' >/dev/null 2>&1; then
  command -v python3 >/dev/null 2>&1 || { echo "ERROR: GNU find features missing and python3 not found (needed for the find shim)" >&2; exit 2; }
  cat > "$T/bin/find" <<'SH'
#!/usr/bin/env python3
# Test-only find shim: emulates the GNU-specific query shapes used by
# backup-to-tape.sh (`-regextype ... -regex RE` and `-printf '%T@ %y %s\n'`);
# falls through to /usr/bin/find for anything else.
import os, re, stat as st_m, subprocess, sys

args = sys.argv[1:]
if '-printf' not in args and '-regextype' not in args:
    sys.exit(subprocess.call(['/usr/bin/find'] + args))

i, paths, mindepth, maxdepth, typ, regex, printf_fmt = 0, [], 0, None, None, None, None
while i < len(args):
    a = args[i]
    if a == '-mindepth': mindepth = int(args[i+1]); i += 2
    elif a == '-maxdepth': maxdepth = int(args[i+1]); i += 2
    elif a == '-type': typ = args[i+1]; i += 2
    elif a == '-regextype': i += 2  # posix-extended matches python re semantics here
    elif a == '-regex': regex = args[i+1]; i += 2
    elif a == '-printf': printf_fmt = args[i+1]; i += 2
    elif a in ('-print', '-print0'): i += 1
    elif a.startswith('-'): i += 1
    else: paths.append(a); i += 1

# backup-to-tape.sh single-quotes the format, so a trailing \n arrives as a
# literal backslash-n; normalize it to a real newline before dispatching.
if printf_fmt == '%T@ %y %s\\n':
    printf_fmt = '%T@ %y %s\n'

if printf_fmt is not None and printf_fmt != '%T@ %y %s\n':
    sys.stderr.write('find shim: unsupported -printf format %r; falling back\n' % printf_fmt)
    sys.exit(subprocess.call(['/usr/bin/find'] + args))

def type_char(m):
    if st_m.S_ISDIR(m): return 'd'
    if st_m.S_ISREG(m): return 'f'
    if st_m.S_ISLNK(m): return 'l'
    return '?'

def type_ok(m, typ):
    if typ is None: return True
    return {'d': st_m.S_ISDIR, 'f': st_m.S_ISREG, 'l': st_m.S_ISLNK}.get(typ, lambda m: False)(m)

rx = re.compile(regex) if regex is not None else None
out = []
def walk(d, depth):
    try:
        names = os.listdir(d)
    except OSError:
        return
    for name in names:
        p = os.path.join(d, name)
        try:
            s = os.stat(p)
        except OSError:
            continue
        isdir = st_m.S_ISDIR(s.st_mode)
        if mindepth <= depth + 1 and (maxdepth is None or depth + 1 <= maxdepth):
            if type_ok(s.st_mode, typ) and (rx is None or rx.fullmatch(p)):
                if printf_fmt == '%T@ %y %s\n':
                    out.append('%d %s %d' % (int(s.st_mtime), type_char(s.st_mode), s.st_size))
                else:
                    out.append(p)
        if isdir and (maxdepth is None or depth + 1 < maxdepth):
            walk(p, depth + 1)

for base in paths:
    try:
        s = os.stat(base)
    except OSError:
        continue
    if mindepth <= 0 and type_ok(s.st_mode, typ) and (rx is None or rx.fullmatch(base)):
        if printf_fmt == '%T@ %y %s\n':
            out.append('%d %s %d' % (int(s.st_mtime), type_char(s.st_mode), s.st_size))
        else:
            out.append(base)
    walk(base, 0)

for line in out:
    sys.stdout.write(line + '\n')
sys.exit(0)
SH
fi

if ! command -v flock >/dev/null 2>&1; then
  cat > "$T/bin/flock" <<'SH'
#!/bin/bash
# Minimal flock for the single-process smoke test (no real locking).
# Forms used by backup-to-tape.sh:
#   flock -x <fd>                     -> no-op
#   flock [-n] [--close] <file> <cmd> -> run cmd, exit with its status
while [[ "${1:-}" == -* ]]; do
  case "$1" in
    -w*|-E*) shift 2 ;;
    *) shift ;;
  esac
done
if [[ $# -eq 1 && "$1" =~ ^[0-9]+$ ]]; then
  exit 0
fi
if [[ $# -ge 2 ]]; then
  shift
  exec "$@"
fi
exec cat
SH
fi

if ! command -v mountpoint >/dev/null 2>&1; then
  cat > "$T/bin/mountpoint" <<'SH'
#!/bin/bash
# Minimal mountpoint: true iff path appears in /etc/mounts (plain dirs -> 1).
[[ "${1:-}" == "-q" ]] && shift
p="${1:-}"
[[ -n "$p" ]] || exit 1
while [[ "$p" == */ && "$p" != "/" ]]; do p="${p%/}"; done
found=0
while read -r dev mnt _rest; do
  [[ "$mnt" == "$p" ]] && { found=1; break; }
done < /etc/mounts
exit $(( 1 - found ))
SH
fi

if ! realpath -m / >/dev/null 2>&1; then
  command -v python3 >/dev/null 2>&1 || { echo "ERROR: realpath -m missing and python3 not found (needed for the realpath shim)" >&2; exit 2; }
  cat > "$T/bin/realpath" <<'SH'
#!/bin/bash
# Minimal GNU realpath for tests: -m (missing ok) / -e, --, multiple paths.
allow_missing=0
args=()
for a in "$@"; do
  case "$a" in
    -m) allow_missing=1 ;;
    -e) allow_missing=0 ;;
    -q|--quiet|--silent) ;;
    --) ;;
    -*) ;;
    *) args+=("$a") ;;
  esac
done
(( ${#args[@]} > 0 )) || args=(.)
rc=0
for p in "${args[@]}"; do
  out=$(python3 - "$p" "$allow_missing" <<'PY2'
import os, sys
path, missing = sys.argv[1], sys.argv[2] == "1"
path = os.path.abspath(path)
for _ in range(40):
    if not os.path.islink(path):
        break
    tgt = os.readlink(path)
    path = os.path.normpath(tgt if os.path.isabs(tgt) else os.path.join(os.path.dirname(path), tgt))
cur = "/"
for part in path.split("/"):
    if part in ("", "."):
        continue
    if part == "..":
        cur = os.path.dirname(cur)
    else:
        cand = "/" + part if cur == "/" else os.path.join(cur, part)
        if os.path.islink(cand):
            tgt = os.readlink(cand)
            cand = os.path.normpath(tgt if os.path.isabs(tgt) else os.path.join(os.path.dirname(cand), tgt))
        cur = cand
print(os.path.normpath(cur))
PY2
)
  if [[ -z "$out" ]]; then rc=1; else printf '%s\n' "$out"; fi
done
exit $rc
SH
fi

if ! printf '' | sort -z >/dev/null 2>&1; then
  cat > "$T/bin/sort" <<'SH'
#!/bin/bash
if [[ "${1:-}" == "-z" ]]; then
  python3 -c 'import sys; values=sys.stdin.buffer.read().split(b"\0"); values=[value for value in values if value]; sys.stdout.buffer.write(b"\0".join(sorted(values)) + (b"\0" if values else b""))'
else
  exec /usr/bin/sort "$@"
fi
SH
fi

cat > "$T/bin/mountpoint" <<'SH'
#!/bin/bash
[[ "${1:-}" == "-q" ]] && shift
[[ "${1:-}" == "${BACKUP_ROOT:-}" && -f "${TEST_MOUNT_MARKER:-}" ]]
SH

chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH"

export MTX_DEV=/dev/null
export SPLUNK_DB="$DB" BACKUP_ROOT="$BR" TEST_MEDIA_ROOT="$MEDIA"
export TEST_MOUNT_MARKER="$T/mounted"
export STATE_DIR="$ST" LOG_DIR="$LD_" LOG_FILE="$LD_/run.log" LOCK_FILE="$T/lock"
export RUN_ID="smoke_$(date +%s)"
export MOUNT_CMD='touch "$TEST_MOUNT_MARKER"' UMOUNT_CMD='rm -f "$TEST_MOUNT_MARKER"'
export SKIP_MOUNT_CHECK=1
export CLEANING_SLOTS=2
export DATA_TAPE_TAG_REGEX='^WA[0-9]+L9$'
export MIN_FREE_BYTES=0 SOFT_LIMIT_BYTES=0
export INCLUDE_DB=1 INCLUDE_RB=1 VERIFY_METHOD=sha256 STOP_ON_COPY_ERROR=1
export BUCKET_MIN_DIR_AGE_SECONDS=1800 BUCKET_MIN_QUIET_SECONDS=900
export DRY_RUN=0
export RUN_UNTIL_DRAINED=1 MAX_DRAIN_PASSES=0
export LOG_LEVEL=info
unset MTX_MOCK_FAIL_LOAD MTX_MOCK_OMIT_DRIVE_TAG

echo "=== RUN 1 (full, forced rotation) ==="
bash "$REPO/backup-to-tape.sh" >/dev/null 2>&1; rc=$?
echo "exit=$rc"
assert "run1 exits 0" test "$rc" -eq 0
assert "rotation happened" grep -q "Rotating tape. Marking current tape as FULL: WA0001L9" "$LD_/run.log"
assert "rotated to next data tape" grep -q "Tape rotated. Now using VolumeTag=WA0003L9" "$LD_/run.log"
assert "cleaning slot skipped" grep -q "Skip slot 2: cleaning cartridge" "$LD_/run.log"
assert "buckets copied" grep -q "Backed up:" "$LD_/run.log"
assert "active bucket deferred" grep -q "Skip (active): main/db_9_9_recent" "$LD_/run.log"
assert "data landed on tape" test -d "$BR/main/db_1_2_a"
assert "ledger has 6 buckets" test "$(grep -c . "$ST/buckets_done.log" 2>/dev/null)" -eq 6
# mtx load progress goes to stdout; the captured tag must be the tag and
# nothing else (exact value incl. the closing quote).
assert "tape tag capture is clean" grep -q 'Current tape: WA0001L9"' "$LD_/run.log"
assert "run_end success" grep -Eq "event=run_end run_id=[^ ]+ status=success" "$LD_/run.log"
# -r over the dir (manifest filenames start with a dot, which *.txt globs miss)
assert "end-of-tape marker mirrored" grep -rq "EndOfTape VolumeTag=WA0001L9" "$ST/tape_manifests"

echo "=== RUN 2 (incremental rerun) ==="
mk_bucket "$DB/security/colddb/db_3_3_new" 6
export RUN_ID="smoke_rerun_$(date +%s)"
export VERIFY_METHOD=size
bash "$REPO/backup-to-tape.sh" >/dev/null 2>&1; rc=$?
echo "exit=$rc"
assert "rerun exits 0" test "$rc" -eq 0
assert "rerun used ledger" grep -q "Skip (ledger):" "$LD_/run.log"
assert "new bucket archived" grep -q "security/db_3_3_new" "$ST/buckets_done.log"
export VERIFY_METHOD=sha256

echo "=== RUN 3 (cleaning cartridge in drive -> exit 14) ==="
cp "$MTX_MOCK_STATE" "$T/state.bak"
{ sed 's/^DRIVE_LOADED=.*/DRIVE_LOADED=1/'; echo "DRIVE_KIND=cleaning"; echo "DRIVE_SLOT=2"; echo "DRIVE_TAG="; cat "$MTX_MOCK_STATE"; } | grep -v '^DRIVE_KIND=data$' > "$T/newstate"
mv "$T/newstate" "$MTX_MOCK_STATE"
: > "$LD_/run.log"
export RUN_ID="smoke_clean_$(date +%s)"
bash "$REPO/backup-to-tape.sh" >/dev/null 2>&1; rc=$?
echo "exit=$rc"
assert "cleaning drive exits 14" test "$rc" -eq 14
assert "run_end reason preserved" grep -q "completion_reason=loaded_cleaning_cartridge" "$LD_/run.log"

echo "=== RUN 4 (disallowed tag in drive -> exit 15) ==="
cp "$T/state.bak" "$MTX_MOCK_STATE"
{ sed 's/^DRIVE_LOADED=.*/DRIVE_LOADED=1/'; echo "DRIVE_KIND=data"; echo "DRIVE_SLOT=1"; echo "DRIVE_TAG=XZZ999"; cat "$MTX_MOCK_STATE" | grep -v '^DRIVE_KIND=' | grep -v '^DRIVE_SLOT=' | grep -v '^DRIVE_TAG='; } > "$T/newstate"
mv "$T/newstate" "$MTX_MOCK_STATE"
: > "$LD_/run.log"
export RUN_ID="smoke_tag_$(date +%s)"
bash "$REPO/backup-to-tape.sh" >/dev/null 2>&1; rc=$?
echo "exit=$rc"
assert "disallowed tag exits 15" test "$rc" -eq 15
assert "run_end reason tag rejected" grep -q "completion_reason=loaded_tape_tag_rejected" "$LD_/run.log"

echo "=== RUN 5 (dry run) ==="
cp "$T/state.bak" "$MTX_MOCK_STATE"
: > "$LD_/run.log"
export RUN_ID="smoke_dry_$(date +%s)"
export DRY_RUN=1
bash "$REPO/backup-to-tape.sh" >/dev/null 2>&1; rc=$?
echo "exit=$rc"
assert "dry run exits 0" test "$rc" -eq 0
assert "dry run stops after 1 pass" grep -q "Dry run: single pass only" "$LD_/run.log"
assert "dry run did not copy" bash -c "! grep -q 'Backed up:' '$LD_/run.log'"

# --- RUN 6..9 rebuild their fixtures from scratch (fresh dirs, media, state) ---
mk_minimal_fixture() {
  # 1 index, 1 backdated bucket, one large-capacity tape, nothing in drive.
  rm -rf "$DB" "$BR" "$MEDIA" "$ST"
  mkdir -p "$DB" "$BR" "$MEDIA" "$ST"
  mkdir -p "$DB/main/colddb"
  mk_bucket "$DB/main/colddb/$1" 8
  mkdir -p "$MEDIA/WA0001L9"
  printf 600000 > "$MEDIA/WA0001L9/.capacity_bytes"
  : > "$LD_/run.log"
  rm -f "$MTX_MOCK_STATE"
  export DRY_RUN=0
  export LOG_LEVEL=info
  unset MTX_MOCK_FAIL_LOAD MTX_MOCK_OMIT_DRIVE_TAG MTX_MOCK_LOAD_TAG_OVERRIDE
}

echo "=== RUN 6 (final rename fails: dst exists as a regular file) ==="
mk_minimal_fixture "db_6_6_x"
# A regular file pre-occupies the final destination: mv(dir -> file) must fail.
mkdir -p "$BR/main"
touch "$BR/main/db_6_6_x"
export RUN_ID="smoke_rename_$(date +%s)"
bash "$REPO/backup-to-tape.sh" >/dev/null 2>&1; rc=$?
echo "exit=$rc"
assert "rename-fail run exits 2" test "$rc" -eq 2
assert "final rename failure logged" grep -q "Final rename failed" "$LD_/run.log"
assert "failed commit not logged as success" bash -c "! grep -q 'Backed up:' '$LD_/run.log'"
assert "ledger empty (failed commit not recorded)" test "$(grep -c . "$ST/buckets_done.log" 2>/dev/null)" -eq 0
assert "catalog has no row for failed commit" test "$(grep -c 'db_6_6_x' "$ST/catalog.csv" 2>/dev/null)" -eq 0
assert "pre-existing file untouched (still a file)" test -f "$BR/main/db_6_6_x"
assert "no stale partial dir left" bash -c "! find '$BR' -name '*.partial-*' 2>/dev/null | grep -q ."
assert "run_end failed/copy_error_stop" grep -Eq "event=run_end run_id=[^ ]+ status=failed completion_reason=copy_error_stop" "$LD_/run.log"
assert "tape tag capture is clean" grep -q 'Current tape: WA0001L9"' "$LD_/run.log"

echo "=== RUN 7 (mtx load fails -> exit 16) ==="
mk_minimal_fixture "db_7_7_x"
export MTX_MOCK_FAIL_LOAD=all
export RUN_ID="smoke_loadfail_$(date +%s)"
bash "$REPO/backup-to-tape.sh" >/dev/null 2>&1; rc=$?
echo "exit=$rc"
assert "load-fail run exits 16" test "$rc" -eq 16
assert "load failure logged" grep -q "Failed to load tape from slot 1" "$LD_/run.log"
assert "no copies attempted" bash -c "! grep -q 'Backed up:' '$LD_/run.log'"
assert "ledger empty" test "$(grep -c . "$ST/buckets_done.log" 2>/dev/null)" -eq 0
assert "run_end failed/tape_load_failed" grep -Eq "event=run_end run_id=[^ ]+ status=failed completion_reason=tape_load_failed" "$LD_/run.log"

echo "=== RUN 8 (mount command fails -> exit 3) ==="
mk_minimal_fixture "db_8_8_x"
export MOUNT_CMD=false
export RUN_ID="smoke_mountfail_$(date +%s)"
bash "$REPO/backup-to-tape.sh" >/dev/null 2>&1; rc=$?
echo "exit=$rc"
assert "mount-fail run exits 3" test "$rc" -eq 3
assert "mount failure logged" grep -q "Failed to mount tape filesystem" "$LD_/run.log"
assert "no copies attempted" bash -c "! grep -q 'Backed up:' '$LD_/run.log'"
assert "run_end failed/mount_failed" grep -Eq "event=run_end run_id=[^ ]+ status=failed completion_reason=mount_failed" "$LD_/run.log"
export MOUNT_CMD='touch "$TEST_MOUNT_MARKER"'

echo "=== RUN 9 (drive status lacks VolumeTag -> last-known fallback) ==="
mk_full_fixture
mkdir -p "$MEDIA/WA0001L9" "$MEDIA/WA0003L9"
printf 10000 > "$MEDIA/WA0001L9/.capacity_bytes"
dd if=/dev/zero of="$MEDIA/WA0001L9/prefill.dat" bs=10000 count=1 status=none 2>/dev/null
printf 600000 > "$MEDIA/WA0003L9/.capacity_bytes"
export MTX_MOCK_OMIT_DRIVE_TAG=1
export LOG_LEVEL=debug
export RUN_ID="smoke_omit_$(date +%s)"
bash "$REPO/backup-to-tape.sh" >/dev/null 2>&1; rc=$?
echo "exit=$rc"
assert "omit-tag run exits 0" test "$rc" -eq 0
assert "rotation happened" grep -q "Tape rotated. Now using VolumeTag=WA0003L9" "$LD_/run.log"
assert "fallback reuses last known tag" grep -q "reusing last known VolumeTag=WA0003L9" "$LD_/run.log"
assert "summary records the new tape" grep -q "last_used_volume_tag=WA0003L9" "$LD_/run.log"
assert "run_end success" grep -Eq "event=run_end run_id=[^ ]+ status=success" "$LD_/run.log"

echo "=== RUN 10 (loaded tape has no verifiable identity -> exit 19) ==="
mk_minimal_fixture "db_10_10_x"
"$T/bin/mtx" -f "$MTX_DEV" status >/dev/null
sed -e 's/^DRIVE_LOADED=.*/DRIVE_LOADED=1/' \
  -e 's/^SLOT_01_FULL=.*/SLOT_01_FULL=0/' "$MTX_MOCK_STATE" > "$T/newstate"
printf '%s\n' 'DRIVE_SLOT=1' 'DRIVE_TAG=WA0001L9' >> "$T/newstate"
mv "$T/newstate" "$MTX_MOCK_STATE"
export MTX_MOCK_OMIT_DRIVE_TAG=1
export RUN_ID="smoke_unknown_tag_$(date +%s)"
bash "$REPO/backup-to-tape.sh" >/dev/null 2>&1; rc=$?
echo "exit=$rc"
assert "unknown-tag run exits 19" test "$rc" -eq 19
assert "unknown-tag run refused before mounting" test ! -f "$TEST_MOUNT_MARKER"
assert "run_end records unknown tape identity" grep -q 'completion_reason=loaded_tape_identity_unknown' "$LD_/run.log"

echo "=== RUN 11 (failed unmount prevents tape unload -> exit 17) ==="
mk_full_fixture
rm -f "$TEST_MOUNT_MARKER"
export UMOUNT_CMD=false
export RUN_ID="smoke_umountfail_$(date +%s)"
bash "$REPO/backup-to-tape.sh" >/dev/null 2>&1; rc=$?
echo "exit=$rc"
assert "unmount-fail run exits 17" test "$rc" -eq 17
assert "cartridge remains loaded after unmount failure" grep -q '^DRIVE_LOADED=1$' "$MTX_MOCK_STATE"
assert "unmounted tape not marked full" bash -c "! grep -Fxq WA0001L9 '$ST/tapes_full.list'"
assert "run_end records unmount failure" grep -q "completion_reason=unmount_failed" "$LD_/run.log"

echo "=== RUN 12 (recover metadata after missing ledger entry) ==="
mk_minimal_fixture "db_12_12_x"
rm -f "$TEST_MOUNT_MARKER"
export UMOUNT_CMD='rm -f "$TEST_MOUNT_MARKER"'
export RUN_ID="smoke_recovery_first_$(date +%s)"
bash "$REPO/backup-to-tape.sh" >/dev/null 2>&1; rc=$?
assert "initial recovery fixture exits 0" test "$rc" -eq 0
grep -Fvx 'main/db_12_12_x' "$ST/buckets_done.log" > "$T/ledger.new" || true
mv "$T/ledger.new" "$ST/buckets_done.log"
export RUN_ID="smoke_recovery_second_$(date +%s)"
bash "$REPO/backup-to-tape.sh" >/dev/null 2>&1; rc=$?
echo "exit=$rc"
assert "recovery run exits 0" test "$rc" -eq 0
assert "missing ledger entry restored" grep -Fxq 'main/db_12_12_x' "$ST/buckets_done.log"
assert "catalog row not duplicated" test "$(grep -c 'WA0001L9,main,db_12_12_x,' "$ST/catalog.csv")" -eq 1
assert "new run manifest contains recovered bucket" grep -Rq 'main/db_12_12_x' "$ST/tape_manifests"

echo "=== RUN 13 (same-size tape corruption rejected by SHA-256) ==="
mk_minimal_fixture "db_13_13_x"
export TEST_CORRUPT_AFTER_RSYNC=1
export RUN_ID="smoke_corrupt_$(date +%s)"
bash "$REPO/backup-to-tape.sh" >/dev/null 2>&1; rc=$?
unset TEST_CORRUPT_AFTER_RSYNC
echo "exit=$rc"
assert "corrupt copy exits 2" test "$rc" -eq 2
assert "SHA-256 mismatch logged" grep -q "SHA-256 verification failed" "$LD_/run.log"
assert "corrupt bucket not committed" test ! -d "$BR/main/db_13_13_x"
assert "corrupt bucket not cataloged" bash -c "! grep -q 'db_13_13_x' '$ST/catalog.csv'"
assert "corrupt partial removed" bash -c "! find '$BR' -name '*.partial-*' 2>/dev/null | grep -q ."

echo "=== RUN 14 (successful umount command leaves mount active -> exit 17) ==="
mk_minimal_fixture "db_14_14_x"
export UMOUNT_CMD=true
export RUN_ID="smoke_umount_still_mounted_$(date +%s)"
bash "$REPO/backup-to-tape.sh" >/dev/null 2>&1; rc=$?
echo "exit=$rc"
assert "still-mounted run exits 17" test "$rc" -eq 17
assert "mountpoint remains detected" test -f "$TEST_MOUNT_MARKER"
assert "summary reports unmount failure" grep -Eq "event=run_summary .*status=failed completion_reason=unmount_failed" "$LD_/run.log"

echo "=== RUN 15 (concurrent backup rejected -> exit 1) ==="
if (( REAL_FLOCK_AVAILABLE == 1 )); then
  mk_minimal_fixture "db_15_15_x"
  rm -f "$TEST_MOUNT_MARKER"
  mkfifo "$T/lock-ready" "$T/lock-release"
  flock -n "$LOCK_FILE" sh -c 'printf ready > "$1"; cat "$2" >/dev/null' sh "$T/lock-ready" "$T/lock-release" &
  lock_pid=$!
  read -r _ < "$T/lock-ready"
  export RUN_ID="smoke_lock_conflict_$(date +%s)"
  bash "$REPO/backup-to-tape.sh" >/dev/null 2>&1; rc=$?
  printf release > "$T/lock-release"
  wait "$lock_pid" || true
  echo "exit=$rc"
  assert "lock conflict exits 1" test "$rc" -eq 1
  assert "lock conflict does not mount tape" test ! -f "$TEST_MOUNT_MARKER"
else
  echo "SKIP: real flock is unavailable; the smoke-test shim does not lock"
fi

echo "=== RUN 16 (loaded barcode mismatches selected slot -> exit 21) ==="
mk_minimal_fixture "db_16_16_x"
rm -f "$TEST_MOUNT_MARKER"
export MTX_MOCK_LOAD_TAG_OVERRIDE=WA9999L9
export RUN_ID="smoke_wrong_tag_$(date +%s)"
bash "$REPO/backup-to-tape.sh" >/dev/null 2>&1; rc=$?
echo "exit=$rc"
assert "wrong-tag load exits 21" test "$rc" -eq 21
assert "wrong-tag tape not mounted" test ! -f "$TEST_MOUNT_MARKER"
assert "run_end records tag mismatch" grep -q 'completion_reason=loaded_tape_identity_mismatch' "$LD_/run.log"

echo ""
if [[ "$FAIL" == 0 ]]; then echo "ALL SMOKE TESTS PASSED"; exit 0; else echo "SOME SMOKE TESTS FAILED"; exit 1; fi
