#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Checkout (clone/update) all GitHub repositories into a directory.

Requires:
  - gh (GitHub CLI) authenticated (run: gh auth login)
  - git
  - python3 (for JSON parsing; avoids jq dependency)

Usage:
  checkout_all_github_repos.sh --dest DIR [options]

Required:
  --dest DIR                 Destination directory to clone into.

Options:
  --owner OWNER              GitHub user/org. Defaults to the authenticated user.
  --protocol ssh|https       Clone protocol. Default: ssh
  --visibility all|public|private
                             Filter by visibility. Default: all
  --include-forks            Include forks (default: excluded)
  --include-archived         Include archived repos (default: excluded)
  --shallow                  Shallow clone new repos (git clone --depth 1)
  --parallel N               Clone/update in parallel (best effort). Default: 1
  --update                   If repo already exists, run: git -C repo pull --ff-only
  --export-list FILE         Write an editable repo list (TSV) and exit.
                             Format: owner/name<TAB>clone_url
  --from-list FILE           Clone/update only repos listed in FILE (TSV or one owner/name per line).
                             Lines starting with # and blank lines are ignored.
  --dry-run                  Print actions without executing.
  -h, --help                 Show this help.

Examples:
  ./checkout_all_github_repos.sh --dest ~/code --owner my-org --protocol https --update --parallel 6
  ./checkout_all_github_repos.sh --dest /mnt/repos --visibility private --include-forks
  ./checkout_all_github_repos.sh --dest ~/code --owner my-org --export-list repos.tsv
  $EDITOR repos.tsv
  ./checkout_all_github_repos.sh --dest ~/code --from-list repos.tsv --update --parallel 6
EOF
}

DEST=""
OWNER=""
PROTOCOL="ssh"
VISIBILITY="all"
INCLUDE_FORKS="false"
INCLUDE_ARCHIVED="false"
SHALLOW="false"
PARALLEL="1"
UPDATE_EXISTING="false"
EXPORT_LIST=""
FROM_LIST=""
DRY_RUN="false"

fail() {
  echo "Error: $*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

run() {
  if [[ "$DRY_RUN" == "true" ]]; then
    printf '[dry-run] %q' "$1"
    shift
    for a in "$@"; do printf ' %q' "$a"; done
    printf '\n'
    return 0
  fi
  "$@"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dest) DEST="${2:-}"; shift 2 ;;
    --owner) OWNER="${2:-}"; shift 2 ;;
    --protocol) PROTOCOL="${2:-}"; shift 2 ;;
    --visibility) VISIBILITY="${2:-}"; shift 2 ;;
    --include-forks) INCLUDE_FORKS="true"; shift ;;
    --include-archived) INCLUDE_ARCHIVED="true"; shift ;;
    --shallow) SHALLOW="true"; shift ;;
    --parallel) PARALLEL="${2:-}"; shift 2 ;;
    --update) UPDATE_EXISTING="true"; shift ;;
    --export-list) EXPORT_LIST="${2:-}"; shift 2 ;;
    --from-list) FROM_LIST="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN="true"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) fail "Unknown argument: $1 (use --help)" ;;
  esac
done

[[ -n "$DEST" ]] || fail "--dest is required (use --help)"
[[ "$PROTOCOL" == "ssh" || "$PROTOCOL" == "https" ]] || fail "--protocol must be ssh or https"
[[ "$VISIBILITY" == "all" || "$VISIBILITY" == "public" || "$VISIBILITY" == "private" ]] || fail "--visibility must be all|public|private"
[[ "$PARALLEL" =~ ^[0-9]+$ ]] || fail "--parallel must be a positive integer"
[[ "$PARALLEL" -ge 1 ]] || fail "--parallel must be >= 1"
if [[ -n "$EXPORT_LIST" && -n "$FROM_LIST" ]]; then
  fail "Use only one of --export-list or --from-list"
fi

need_cmd gh
need_cmd git
need_cmd python3

if ! gh auth status >/dev/null 2>&1; then
  fail "gh is not authenticated. Run: gh auth login"
fi

if [[ -z "$OWNER" ]]; then
  OWNER="$(gh api user --jq '.login' 2>/dev/null || true)"
  [[ -n "$OWNER" ]] || fail "Unable to determine authenticated user. Pass --owner explicitly."
fi

run mkdir -p "$DEST"

get_filtered_repo_lines() {
  if [[ "$DRY_RUN" == "true" ]]; then
    return 0
  fi
  # Pull all repos for owner (user or org), then filter locally.
  # Note: gh's available --json fields vary by version. We stick to broadly-supported ones.
  # For HTTPS cloning, we derive the clone URL from the web URL by appending ".git".
  gh repo list "$OWNER" --limit 100000 --json nameWithOwner,sshUrl,url,isFork,isArchived,isPrivate --jq '.' | \
  python3 -c '
import json, sys
protocol = sys.argv[1]
visibility = sys.argv[2]
include_forks = sys.argv[3].lower() == "true"
include_archived = sys.argv[4].lower() == "true"

raw = sys.stdin.read()
raw = raw.strip()
# Robust parsing: sometimes gh may emit extra non-JSON text; extract the first JSON array.
payload = raw
start = raw.find("[")
end = raw.rfind("]")
if start != -1 and end != -1 and end > start:
    payload = raw[start : end + 1]
try:
    repos = json.loads(payload) if payload else []
except Exception:
    repos = []
for r in repos:
    if not include_forks and r.get("isFork"):
        continue
    if not include_archived and r.get("isArchived"):
        continue
    if visibility == "private" and not r.get("isPrivate"):
        continue
    if visibility == "public" and r.get("isPrivate"):
        continue
    if protocol == "ssh":
        url = r.get("sshUrl")
    else:
        web = r.get("url")
        url = (web + ".git") if (web and not web.endswith(".git")) else web
    name = r.get("nameWithOwner")
    if url and name:
        print(f"{name}\t{url}")
' "$PROTOCOL" "$VISIBILITY" "$INCLUDE_FORKS" "$INCLUDE_ARCHIVED"
}

resolve_url_for_name() {
  local name="$1"
  if [[ "$PROTOCOL" == "ssh" ]]; then
    gh api "repos/$name" --jq '.ssh_url'
  else
    gh api "repos/$name" --jq '.clone_url'
  fi
}

read_repo_lines_from_file() {
  local file="$1"
  [[ -f "$file" ]] || fail "--from-list file not found: $file"
  python3 - "$file" <<'PY'
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    for raw in f:
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        # Preserve tabs if present; otherwise keep as-is
        print(line)
PY
}

if [[ -n "$EXPORT_LIST" ]]; then
  if [[ -e "$EXPORT_LIST" && ! -f "$EXPORT_LIST" ]]; then
    fail "--export-list path exists and is not a file: $EXPORT_LIST"
  fi
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[dry-run] Would query repos for owner '$OWNER' and write list to: $EXPORT_LIST"
    exit 0
  fi
  EXPORT_LIST_ABS="$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$EXPORT_LIST" 2>/dev/null || echo "$EXPORT_LIST")"
  readarray -t LINES < <(get_filtered_repo_lines)
  # Keep only valid exported entries: owner/name<TAB>url
  filtered=()
  for l in "${LINES[@]}"; do
    if [[ "$l" == *$'\t'* ]]; then
      name="${l%%$'\t'*}"
      url="${l#*$'\t'}"
      if [[ "$name" == */* && "$url" == *github.com* ]]; then
        filtered+=("$l")
      fi
    fi
  done
  LINES=("${filtered[@]}")

  # Safety: make sure the repo containing this script is present in the export.
  # This avoids any edge cases where the first JSON element might be dropped.
  SCRIPT_REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  SCRIPT_REPO_NAME="$(basename "$SCRIPT_REPO_DIR")"
  SELF_NAME="${OWNER}/${SCRIPT_REPO_NAME}"
  SELF_LINE=""
  if [[ "$PROTOCOL" == "ssh" ]]; then
    TAB=$'\t'
    SELF_LINE="${SELF_NAME}${TAB}git@github.com:${SELF_NAME}.git"
  else
    TAB=$'\t'
    SELF_LINE="${SELF_NAME}${TAB}https://github.com/${SELF_NAME}.git"
  fi
  has_self=false
  for l in "${LINES[@]}"; do
    # Export lines should either be "owner/name<TAB>url" or "owner/name"
    if [[ "$l" == "${SELF_NAME}" || "$l" == "${SELF_NAME}"$'\t'* ]]; then
      has_self=true
      break
    fi
  done
  if [[ "$has_self" != "true" ]]; then
    LINES+=("$SELF_LINE")
  fi
  if [[ "${#LINES[@]}" -eq 0 ]]; then
    echo "No repositories matched the selected filters for owner '$OWNER'."
    exit 0
  fi

  # Final strict filter right before writing:
  # keep ONLY lines in the form "owner/name<TAB>github-url".
  strict=()
  for l in "${LINES[@]}"; do
    if [[ "$l" == *$'\t'* ]]; then
      name="${l%%$'\t'*}"
      url="${l#*$'\t'*}"
      if [[ "$name" == */* ]]; then
        if [[ "$PROTOCOL" == "ssh" && "$url" == git@github.com:* ]]; then
          strict+=("$l")
        elif [[ "$PROTOCOL" == "https" && "$url" == https://github.com/* ]]; then
          strict+=("$l")
        fi
      fi
    fi
  done
  LINES=("${strict[@]}")

  if [[ "${#LINES[@]}" -eq 0 ]]; then
    fail "Export produced no valid repo entries (owner='$OWNER', protocol='$PROTOCOL')."
  fi
  mkdir -p "$(dirname "$EXPORT_LIST")"
  # Determinism guard: after writing the file, ensure the script's own repo is present.
  # (This prevents any edge-case where an export parse drops the first element.)
  {
    echo "# Repo list (editable). One per line."
    echo "# Format: owner/name<TAB>clone_url"
    echo "# You can also delete the URL column and leave just owner/name (script will resolve URL at runtime)."
    printf '%s\n' "${LINES[@]}"
  } >"$EXPORT_LIST"

  # Final scrub: remove any non-matching lines (e.g. stray "56") to make export deterministic.
  python3 - "$EXPORT_LIST" "$SELF_NAME" "$SELF_LINE" <<'PY'
import re, sys

path = sys.argv[1]
self_name = sys.argv[2]
self_line = sys.argv[3]

tab_line_re = re.compile(r"^[^#\s]+/[^#\s]+\t.+$")
github_url_re = re.compile(r"github\.com[:/]")

out_lines = []
present = False

with open(path, "r", encoding="utf-8") as f:
    for raw in f:
        line = raw.rstrip("\n")
        if not line:
            continue
        if line.startswith("#"):
            out_lines.append(line)
            continue

        # Allow either:
        #   owner/name<TAB>url   (preferred)
        #   owner/name           (supported by --from-list)
        if "\t" in line:
            if tab_line_re.match(line) and github_url_re.search(line):
                out_lines.append(line)
                if line.startswith(self_name + "\t"):
                    present = True
        else:
            if line == self_name:
                present = True
                out_lines.append(line)
            # Drop everything else (including stray "56")

if not present and self_line:
    out_lines.append(self_line)

with open(path, "w", encoding="utf-8") as f:
    f.write("\n".join(out_lines) + "\n")
PY

  echo "Wrote repo list: $EXPORT_LIST_ABS"
  exit 0
fi

if [[ -n "$FROM_LIST" ]]; then
  readarray -t LINES < <(read_repo_lines_from_file "$FROM_LIST")
else
  readarray -t LINES < <(get_filtered_repo_lines)
fi

 # Keep only valid curated entries:
 # - owner/name<TAB>url
 # - or owner/name
filtered=()
for l in "${LINES[@]}"; do
  if [[ "$l" == *$'\t'* ]]; then
    name="${l%%$'\t'*}"
    if [[ "$name" == */* ]]; then
      filtered+=("$l")
    fi
  else
    if [[ "$l" == */* ]]; then
      filtered+=("$l")
    fi
  fi
done
LINES=("${filtered[@]}")

if [[ "${#LINES[@]}" -eq 0 ]]; then
  if [[ -n "$FROM_LIST" ]]; then
    echo "No repositories found in list file: $FROM_LIST"
  else
    echo "No repositories matched the selected filters for owner '$OWNER'."
  fi
  exit 0
fi

do_one() {
  local name="$1"
  local url="$2"
  local repo_dir="$DEST/${name#*/}"

  if [[ -d "$repo_dir/.git" ]]; then
    echo "Exists: $repo_dir"
    if [[ "$UPDATE_EXISTING" == "true" ]]; then
      echo "Updating: $name"
      run git -C "$repo_dir" pull --ff-only
    fi
    return 0
  fi

  if [[ -e "$repo_dir" && ! -d "$repo_dir" ]]; then
    echo "Skipping (path exists, not a dir): $repo_dir" >&2
    return 0
  fi

  if [[ -d "$repo_dir" && ! -d "$repo_dir/.git" ]]; then
    echo "Skipping (dir exists but not a git repo): $repo_dir" >&2
    return 0
  fi

  echo "Cloning: $name -> $repo_dir"
  if [[ "$SHALLOW" == "true" ]]; then
    run git clone --depth 1 "$url" "$repo_dir"
  else
    run git clone "$url" "$repo_dir"
  fi
}

export -f do_one fail need_cmd run resolve_url_for_name
export DEST UPDATE_EXISTING SHALLOW DRY_RUN PROTOCOL

if [[ "$PARALLEL" -eq 1 ]]; then
  for line in "${LINES[@]}"; do
    if [[ "$line" == *$'\t'* ]]; then
      name="${line%%$'\t'*}"
      url="${line#*$'\t'}"
    else
      name="$line"
      url="$(resolve_url_for_name "$name")"
    fi
    do_one "$name" "$url"
  done
else
  # best-effort parallelization
  need_cmd xargs
  printf '%s\n' "${LINES[@]}" | xargs -P "$PARALLEL" -n 1 -I '{}' bash -lc '
    set -euo pipefail
    line="$1"
    if [[ "$line" == *$'\''\t'\''* ]]; then
      name="${line%%$'\''\t'\''*}"
      url="${line#*$'\''\t'\''}"
    else
      name="$line"
      url="$(resolve_url_for_name "$name")"
    fi
    do_one "$name" "$url"
  ' _ '{}'
fi

echo "Done. Destination: $DEST"
