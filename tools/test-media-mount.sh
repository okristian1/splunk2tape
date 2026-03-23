#!/usr/bin/env bash
set -Eeuo pipefail

action="${1:-}"
state_file="${MTX_MOCK_STATE:-/tmp/mtx-mock.state}"
backup_root="${BACKUP_ROOT:?BACKUP_ROOT required}"
media_root="${TEST_MEDIA_ROOT:?TEST_MEDIA_ROOT required}"

if [[ -f "$state_file" ]]; then
  # shellcheck disable=SC1090
  source "$state_file"
fi

mount_media() {
  local tag="${DRIVE_TAG:-}"
  local media_dir

  if [[ -z "$tag" ]]; then
    echo "No data tape loaded in drive" >&2
    exit 1
  fi

  media_dir="$media_root/$tag"
  mkdir -p "$media_dir" "$backup_root"

  if mountpoint -q "$backup_root" 2>/dev/null; then
    umount "$backup_root"
  fi

  mount --bind "$media_dir" "$backup_root"
}

umount_media() {
  if mountpoint -q "$backup_root" 2>/dev/null; then
    umount "$backup_root"
  fi
}

case "$action" in
  mount)
    mount_media
    ;;
  umount)
    umount_media
    ;;
  *)
    echo "Usage: $0 mount|umount" >&2
    exit 2
    ;;
esac