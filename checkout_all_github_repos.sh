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
  --dry-run                  Print actions without executing.
  -h, --help                 Show this help.

Examples:
  ./checkout_all_github_repos.sh --dest ~/code --owner my-org --protocol https --update --parallel 6
  ./checkout_all_github_repos.sh --dest /mnt/repos --visibility private --include-forks
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

TMP_JSON="$(mktemp)"
cleanup() { rm -f "$TMP_JSON"; }
trap cleanup EXIT

# Pull all repos for owner (user or org), then filter locally.
run gh repo list "$OWNER" --limit 100000 --json nameWithOwner,sshUrl,cloneUrl,isFork,isArchived,isPrivate --jq '.' >"$TMP_JSON"

readarray -t LINES < <(
  python3 - "$PROTOCOL" "$VISIBILITY" "$INCLUDE_FORKS" "$INCLUDE_ARCHIVED" <"$TMP_JSON" <<'PY'
import json, sys

protocol = sys.argv[1]
visibility = sys.argv[2]
include_forks = sys.argv[3].lower() == "true"
include_archived = sys.argv[4].lower() == "true"

repos = json.load(sys.stdin)
for r in repos:
    if not include_forks and r.get("isFork"):
        continue
    if not include_archived and r.get("isArchived"):
        continue
    if visibility == "private" and not r.get("isPrivate"):
        continue
    if visibility == "public" and r.get("isPrivate"):
        continue
    url = r.get("sshUrl") if protocol == "ssh" else r.get("cloneUrl")
    name = r.get("nameWithOwner")
    if url and name:
        print(f"{name}\t{url}")
PY
)

if [[ "${#LINES[@]}" -eq 0 ]]; then
  echo "No repositories matched the selected filters for owner '$OWNER'."
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

export -f do_one fail need_cmd run
export DEST UPDATE_EXISTING SHALLOW DRY_RUN

if [[ "$PARALLEL" -eq 1 ]]; then
  for line in "${LINES[@]}"; do
    name="${line%%$'\t'*}"
    url="${line#*$'\t'}"
    do_one "$name" "$url"
  done
else
  # best-effort parallelization
  need_cmd xargs
  printf '%s\n' "${LINES[@]}" | xargs -P "$PARALLEL" -n 1 -I '{}' bash -lc '
    set -euo pipefail
    line="$1"
    name="${line%%$'\''\t'\''*}"
    url="${line#*$'\''\t'\''}"
    do_one "$name" "$url"
  ' _ '{}'
fi

echo "Done. Destination: $DEST"
