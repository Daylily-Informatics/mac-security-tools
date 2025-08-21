# Save as: mac_software_changes_last3d.sh
# Usage:
#   bash mac_software_changes_last3d.sh \
#     --start-date "$(date -v-3d +%s)" \
#     --end-datetime "$(date +%s)" \
#   | tee ~/Desktop/changes-$(hostname)-$(date +%Y%m%d%H%M).txt

#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: mac_software_changes_last3d.sh [--start-date <epoch_seconds>] [--end-datetime <epoch_seconds>] [--help]

Generates a report of software additions/changes on macOS between START and END.

Options:
  --start-date <epoch_seconds>     Start of window (UTC epoch seconds). Alias: --start-datetime
  --end-datetime <epoch_seconds>   End of window (UTC epoch seconds).   Alias: --end-date
  -h, --help                       Show this help and exit.

Defaults:
  If no args are provided, START = now - 3 days, END = now.

Examples:
  # Last 3 days (default)
  bash mac_software_changes_last3d.sh

  # Explicit window
  bash mac_software_changes_last3d.sh \
    --start-date "$(date -v-3d +%s)" \
    --end-datetime "$(date +%s)" \
    | tee ~/Desktop/changes-$(hostname)-$(date +%Y%m%d%H%M).txt
USAGE
}

START_EPOCH=""
END_EPOCH=""

# --- Parse CLI args (accept a couple of symmetric aliases for convenience) ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage; exit 0 ;;
    --start-date|--start-datetime)
      [[ $# -ge 2 ]] || { echo "Error: $1 requires <epoch_seconds>" >&2; exit 2; }
      START_EPOCH="$2"; shift 2 ;;
    --end-datetime|--end-date)
      [[ $# -ge 2 ]] || { echo "Error: $1 requires <epoch_seconds>" >&2; exit 2; }
      END_EPOCH="$2"; shift 2 ;;
    *)
      echo "Unknown argument: $1" >&2
      echo; usage; exit 2 ;;
  esac
done

# --- Derive defaults per requirement: if no args, start = now-3d, end = now ---
if [[ -z "${START_EPOCH}" && -z "${END_EPOCH}" ]]; then
  END_EPOCH="$(date +%s)"
  START_EPOCH="$(( END_EPOCH - 3*24*3600 ))"
elif [[ -z "${START_EPOCH}" ]]; then
  # If only end was provided, default start to end - 3d
  START_EPOCH="$(( END_EPOCH - 3*24*3600 ))"
elif [[ -z "${END_EPOCH}" ]]; then
  # If only start was provided, default end to now
  END_EPOCH="$(date +%s)"
fi

# --- Validate ---
[[ "${START_EPOCH}" =~ ^[0-9]+$ ]] || { echo "START must be epoch seconds, got: ${START_EPOCH}" >&2; exit 2; }
[[ "${END_EPOCH}"   =~ ^[0-9]+$ ]] || { echo "END must be epoch seconds, got: ${END_EPOCH}" >&2; exit 2; }
if (( END_EPOCH < START_EPOCH )); then
  echo "Error: END (${END_EPOCH}) is earlier than START (${START_EPOCH})." >&2
  exit 2
fi

export START_EPOCH END_EPOCH

# --- Human-readable window + derived durations ---
START_HUMAN="$(date -r "${START_EPOCH}" '+%Y-%m-%d %H:%M:%S %z')"
END_HUMAN="$(date -r "${END_EPOCH}"   '+%Y-%m-%d %H:%M:%S %z')"
RANGE_SEC=$(( END_EPOCH - START_EPOCH ))
RANGE_HOURS=$(( RANGE_SEC / 3600 ))

section() { printf "\n### %s\n\n" "$1"; }

printf "## macOS software changes between %s and %s (~%sh)\n" "$START_HUMAN" "$END_HUMAN" "$RANGE_HOURS"

# --- Reference files for precise find() time-window filters ---
START_REF="$(mktemp -t startref)"
END_REF="$(mktemp -t endref)"
trap 'rm -f "$START_REF" "$END_REF"' EXIT
touch -t "$(date -r "${START_EPOCH}" '+%Y%m%d%H%M.%S')" "$START_REF"
touch -t "$(date -r "${END_EPOCH}"   '+%Y%m%d%H%M.%S')" "$END_REF"

# ----------------------------------------------------------------------
# Install history — Apple Installer, App Store, macOS updates (InstallHistory.plist)
# ----------------------------------------------------------------------
section "Install history (Installer + App Store + macOS) — ${START_HUMAN} → ${END_HUMAN}"
python3 - <<'PY'
import plistlib, datetime, os
start = datetime.datetime.fromtimestamp(int(os.environ['START_EPOCH']), datetime.timezone.utc)
end   = datetime.datetime.fromtimestamp(int(os.environ['END_EPOCH']),   datetime.timezone.utc)
path = "/Library/Receipts/InstallHistory.plist"
try:
    with open(path, "rb") as f:
        items = plistlib.load(f)
except Exception as e:
    print(f"(could not read {path}: {e})")
    items = []
hits = []
for it in items:
    dt = it.get("date")
    if not dt:
        continue
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=datetime.timezone.utc)
    if start <= dt <= end:
        hits.append((dt, it))
for dt, it in sorted(hits, key=lambda x: x[0]):
    name = it.get("displayName","")
    ver  = it.get("displayVersion","")
    proc = it.get("processName","")
    pkgs = ", ".join(it.get("packageIdentifiers",[]))
    print(f"{dt.isoformat(timespec='seconds')}  [{proc}]  {name} {ver}  {pkgs}")
PY

# ----------------------------------------------------------------------
# pkgutil receipts — show packages whose install-time is in the window
# ----------------------------------------------------------------------
section "pkgutil receipts (extra signal) — ${START_HUMAN} → ${END_HUMAN}"
while IFS= read -r p; do
  t="$(pkgutil --pkg-info "$p" 2>/dev/null | awk -F': ' '/install-time/{print $2}')"
  if [[ -n "${t:-}" ]] && [[ "$t" =~ ^[0-9]+$ ]]; then
    if (( t >= START_EPOCH && t <= END_EPOCH )); then
      echo "$(date -r "$t" '+%Y-%m-%dT%H:%M:%S%z')  $p"
    fi
  fi
done < <(pkgutil --pkgs)

# ----------------------------------------------------------------------
# Homebrew (formulae + casks) — windowed on file mtimes
# ----------------------------------------------------------------------
if command -v brew >/dev/null 2>&1; then
  BREW_PREFIX="$(brew --prefix)"
  CELLAR="$(brew --cellar)"
  CASKROOM="$BREW_PREFIX/Caskroom"

  section "Homebrew formulae — ${START_HUMAN} → ${END_HUMAN}"
  if [[ -d "$CELLAR" ]]; then
    # Look for INSTALL_RECEIPT.json in each keg, filter by mtime window
    while IFS= read -r -d '' f; do
      ts_epoch="$(stat -f '%m' "$f")"
      if (( ts_epoch >= START_EPOCH && ts_epoch <= END_EPOCH )); then
        ts_human="$(stat -f '%Sm' -t '%Y-%m-%dT%H:%M:%S%z' "$f")"
        # Extract "name version" from .../Cellar/<name>/<version>/INSTALL_RECEIPT.json
        formula="$(echo "$f" | sed -E "s|$CELLAR/([^/]+)/([^/]+)/.*|\1 \2|")"
        echo "$ts_human  $formula"
      fi
    done < <(find "$CELLAR" -maxdepth 3 -name INSTALL_RECEIPT.json -type f -print0)
  fi

  section "Homebrew casks — ${START_HUMAN} → ${END_HUMAN}"
  if [[ -d "$CASKROOM" ]]; then
    # Each versioned cask dir: Caskroom/<cask>/<version>
    while IFS= read -r -d '' d; do
      ts_epoch="$(stat -f '%m' "$d")"
      if (( ts_epoch >= START_EPOCH && ts_epoch <= END_EPOCH )); then
        ts_human="$(stat -f '%Sm' -t '%Y-%m-%dT%H:%M:%S%z' "$d")"
        name="$(basename "$(dirname "$d")")"
        ver="$(basename "$d")"
        echo "$ts_human  $name $ver"
      fi
    done < <(find "$CASKROOM" -maxdepth 2 -mindepth 2 -type d -print0)
  fi
fi

# ----------------------------------------------------------------------
# LaunchAgents/Daemons changed in window (system + user)
# ----------------------------------------------------------------------
section "LaunchAgents/Daemons changed — ${START_HUMAN} → ${END_HUMAN}"
for dir in /Library/LaunchAgents /Library/LaunchDaemons; do
  if [[ -d "$dir" ]]; then
    # needs sudo for complete coverage of system dirs
    sudo find "$dir" -type f -newer "$START_REF" ! -newer "$END_REF" -print || true
  fi
done
if [[ -d "$HOME/Library/LaunchAgents" ]]; then
  find "$HOME/Library/LaunchAgents" -type f -newer "$START_REF" ! -newer "$END_REF" -print
fi

# ----------------------------------------------------------------------
# Application bundles touched in window (system + user Applications)
# ----------------------------------------------------------------------
section "Application bundles touched — ${START_HUMAN} → ${END_HUMAN}"
for ap in "/Applications" "$HOME/Applications"; do
  if [[ -d "$ap" ]]; then
    find "$ap" -maxdepth 1 -name "*.app" -newer "$START_REF" ! -newer "$END_REF" -print
  fi
done

# ----------------------------------------------------------------------
# Unified log (softwareupdate/appstoreagent) — windowed
# ----------------------------------------------------------------------
section "Unified log (softwareupdate/appstoreagent) — ${START_HUMAN} → ${END_HUMAN} (best-effort)"
# Note: unified logs rotate; this is a helpful but non-authoritative supplement.
log show --style compact \
  --start "$START_HUMAN" --end "$END_HUMAN" \
  --info --debug \
  --predicate '(subsystem == "com.apple.SoftwareUpdate" || process == "softwareupdated" || process == "appstoreagent" || process == "App Store") && (eventMessage CONTAINS[c] "Install" || eventMessage CONTAINS[c] "update" || eventMessage CONTAINS[c] "download")' \
  2>/dev/null | tail -n +1
