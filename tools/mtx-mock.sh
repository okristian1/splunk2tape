#!/usr/bin/env bash
# Mock mtx for testing without a tape library (RHEL 9 VM).
# Keeps state in /tmp/mtx-mock.state
# Test hooks (opt-in env vars, all default to no-op):
#   MTX_MOCK_FAIL_LOAD=all|<slot>   make load fail for given slot(s)
#   MTX_MOCK_OMIT_DRIVE_TAG=1       drive status line without :VolumeTag=
#   MTX_MOCK_LOAD_TAG_OVERRIDE=<tag> report an unexpected tag after load
set -euo pipefail

STATE_FILE="${MTX_MOCK_STATE:-/tmp/mtx-mock.state}"
SLOT_FIRST="${SLOT_FIRST:-1}"
SLOT_LAST="${SLOT_LAST:-40}"
TAPE_DRIVE="${TAPE_DRIVE:-0}"
TAG_PREFIX="${TAG_PREFIX:-WA}"
TAG_SUFFIX="${TAG_SUFFIX:-L9}"
CLEANING_SLOTS="${CLEANING_SLOTS:-}"

slot_is_cleaning() {
  local slot="$1"
  case ",${CLEANING_SLOTS}," in
    *,${slot},*) return 0 ;;
    *) return 1 ;;
  esac
}

init_state() {
  if [[ -f "$STATE_FILE" ]]; then
    return 0
  fi
  # Default: all slots full with sequential tags; no tape loaded in drive.
  {
    echo "DRIVE_LOADED=0"
    echo "DRIVE_KIND=data"
    for ((s=SLOT_FIRST; s<=SLOT_LAST; s++)); do
      printf "SLOT_%02d_FULL=1\n" "$s"
      if slot_is_cleaning "$s"; then
        printf "SLOT_%02d_TAG=CLEANING_TAPE\n" "$s"
      else
        printf "SLOT_%02d_TAG=%s%04d%s\n" "$s" "$TAG_PREFIX" "$s" "$TAG_SUFFIX"
      fi
    done
  } > "$STATE_FILE"
}

load_state() {
  # shellcheck disable=SC1090
  source "$STATE_FILE"
}

save_state() {
  : > "$STATE_FILE"
  printf "DRIVE_LOADED=%s\n" "$DRIVE_LOADED" >> "$STATE_FILE"
  printf "DRIVE_KIND=%s\n" "${DRIVE_KIND:-data}" >> "$STATE_FILE"
  # Persist which slot/tag is in the drive so status works across calls
  if [[ "$DRIVE_LOADED" == "1" ]]; then
    printf "DRIVE_SLOT=%s\n" "$DRIVE_SLOT" >> "$STATE_FILE"
    printf "DRIVE_TAG=%s\n" "$DRIVE_TAG" >> "$STATE_FILE"
  fi
  for ((s=SLOT_FIRST; s<=SLOT_LAST; s++)); do
    local key_full key_tag
    key_full=$(printf "SLOT_%02d_FULL" "$s")
    key_tag=$(printf "SLOT_%02d_TAG" "$s")
    printf "%s=%s\n" "$key_full" "${!key_full}" >> "$STATE_FILE"
    printf "%s=%s\n" "$key_tag" "${!key_tag}" >> "$STATE_FILE"
  done
}

status_cmd() {
  if [[ "$DRIVE_LOADED" == "1" ]]; then
    if [[ "${DRIVE_KIND:-data}" == "cleaning" ]]; then
      echo "Data Transfer Element $TAPE_DRIVE:Full (Storage Element ${DRIVE_SLOT} Loaded):Cleaning Cartridge"
    else
      local drive_line="Data Transfer Element $TAPE_DRIVE:Full (Storage Element ${DRIVE_SLOT} Loaded)"
      # Some real mtx builds do not include the VolumeTag on the drive line;
      # MTX_MOCK_OMIT_DRIVE_TAG=1 emulates that to test the last-known-tag
      # fallback path in ensure_tape_ready.
      if [[ "${MTX_MOCK_OMIT_DRIVE_TAG:-0}" != "1" && -n "${DRIVE_TAG:-}" ]]; then
        drive_line="${drive_line}:VolumeTag=${DRIVE_TAG}"
      fi
      echo "$drive_line"
    fi
  else
    echo "Data Transfer Element $TAPE_DRIVE:Empty"
  fi
  for ((s=SLOT_FIRST; s<=SLOT_LAST; s++)); do
    local key_full key_tag
    key_full=$(printf "SLOT_%02d_FULL" "$s")
    key_tag=$(printf "SLOT_%02d_TAG" "$s")
    if [[ "${!key_full}" == "1" ]]; then
      if slot_is_cleaning "$s"; then
        echo "      Storage Element $s:Full :Cleaning Cartridge"
      else
        echo "      Storage Element $s:Full :VolumeTag=${!key_tag}"
      fi
    else
      echo "      Storage Element $s:Empty"
    fi
  done
}

load_cmd() {
  local slot="$1"
  # MTX_MOCK_FAIL_LOAD=all|<slot> forces a load failure before any state
  # change, to test the script's load-failure handling.
  local fail_load="${MTX_MOCK_FAIL_LOAD:-}"
  if [[ -n "$fail_load" && ( "$fail_load" == "all" || "$fail_load" == "$slot" ) ]]; then
    echo "Drive $TAPE_DRIVE: load of storage $slot failed (mock)" >&2
    exit 1
  fi
  if [[ "$DRIVE_LOADED" == "1" ]]; then
    echo "Drive already loaded" >&2
    exit 1
  fi
  local key_full key_tag
  key_full=$(printf "SLOT_%02d_FULL" "$slot")
  key_tag=$(printf "SLOT_%02d_TAG" "$slot")
  if [[ "${!key_full}" != "1" ]]; then
    echo "Slot $slot is empty" >&2
    exit 1
  fi
  # Real mtx prints load progress to stdout; emit it (faithfully) so tests
  # can verify the backup script keeps stdout clean for its captured tag.
  echo "At storage $slot"
  echo "Moving to position 100"
  echo "Storage $slot loaded"
  DRIVE_LOADED=1
  DRIVE_SLOT="$slot"
  if slot_is_cleaning "$slot"; then
    DRIVE_KIND="cleaning"
    DRIVE_TAG=""
  else
    DRIVE_KIND="data"
    DRIVE_TAG="${MTX_MOCK_LOAD_TAG_OVERRIDE:-${!key_tag}}"
  fi
  eval "$key_full=0"
  eval "$key_tag="
  save_state
}

unload_cmd() {
  local slot="$1"
  if [[ "$DRIVE_LOADED" != "1" ]]; then
    echo "Drive empty" >&2
    exit 1
  fi
  local key_full key_tag
  key_full=$(printf "SLOT_%02d_FULL" "$slot")
  key_tag=$(printf "SLOT_%02d_TAG" "$slot")
  if [[ "${!key_full}" == "1" ]]; then
    echo "Slot $slot already full" >&2
    exit 1
  fi
  eval "$key_full=1"
  if slot_is_cleaning "$slot" || [[ "${DRIVE_KIND:-data}" == "cleaning" ]]; then
    eval "$key_tag=CLEANING_TAPE"
  else
    eval "$key_tag=$DRIVE_TAG"
  fi
  DRIVE_LOADED=0
  DRIVE_KIND="data"
  unset DRIVE_SLOT DRIVE_TAG
  save_state
}

main() {
  init_state
  load_state

  # Basic mtx interface: mtx -f <dev> status|load <slot> <drive>|unload <slot> <drive>
  # Accept calls with or without -f <dev>
  local cmd
  if [[ "${1:-}" == "-f" ]]; then
    shift 2
  fi
  cmd="${1:-}"
  case "$cmd" in
    status)
      status_cmd
      ;;
    load)
      load_cmd "${2:?slot required}"
      ;;
    unload)
      unload_cmd "${2:?slot required}"
      ;;
    *)
      echo "Unsupported mock mtx command" >&2
      exit 2
      ;;
  esac
}

main "$@"
