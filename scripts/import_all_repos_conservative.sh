#!/usr/bin/env bash
set -euo pipefail

# Very conservative importer for the Unified Autonomy Stack .repos files.
#
# What this script does differently from import_all_repos.sh:
#   - Still uses `vcs import`.
#   - Splits every .repos file into temporary one-repository .repos files.
#   - Runs exactly one `vcs import` at a time.
#   - Forces vcstool to use one worker when supported.
#   - Adds Git config limits for conservative HTTP/fetch/submodule behavior.
#   - Sleeps between every individual repository and between every .repos file.
#   - Adds retries with a long cooldown.
#   - Keeps the original robot_bringup special import and mmwave_ti_ros patch behavior.
#
# Usage:
#   ./scripts/import_all_repos_conservative.sh
#   ./scripts/import_all_repos_conservative.sh --exact
#
# Useful overrides:
#   SLEEP_BETWEEN_REPOS=10 ./scripts/import_all_repos_conservative.sh
#   SLEEP_BETWEEN_REPOS_FILES=10 ./scripts/import_all_repos_conservative.sh
#   MAX_RETRIES=8 RETRY_SLEEP=300 ./scripts/import_all_repos_conservative.sh
#   SHALLOW_IMPORT=false ./scripts/import_all_repos_conservative.sh

# -------------------------
# User-tunable conservatism
# -------------------------
SLEEP_BETWEEN_REPOS="${SLEEP_BETWEEN_REPOS:-10}"
SLEEP_BETWEEN_REPOS_FILES="${SLEEP_BETWEEN_REPOS_FILES:-10}"
RETRY_SLEEP="${RETRY_SLEEP:-180}"
MAX_RETRIES="${MAX_RETRIES:-5}"

# true saves bandwidth for normal branch/tag versions.
# The script automatically disables shallow mode for commit-SHA versions.
SHALLOW_IMPORT="${SHALLOW_IMPORT:-true}"

# Set to true if you want to see actions without importing.
DRY_RUN="${DRY_RUN:-false}"

# Keep temporary split .repos files for debugging.
KEEP_TEMP="${KEEP_TEMP:-false}"

# -------------------------
# Paths
# -------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UAS_REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPOS_DIR="$UAS_REPO_ROOT/repos"
WORKSPACES_DIR="$UAS_REPO_ROOT/workspaces"

# -------------------------
# Colors
# -------------------------
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# -------------------------
# Arguments
# -------------------------
USE_EXACT=false

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --exact)
            USE_EXACT=true
            ;;
        --no-shallow)
            SHALLOW_IMPORT=false
            ;;
        --shallow)
            SHALLOW_IMPORT=true
            ;;
        --dry-run)
            DRY_RUN=true
            ;;
        -h|--help)
            cat <<EOF
Usage:
  $0 [--exact] [--no-shallow] [--shallow] [--dry-run]

Environment overrides:
  SLEEP_BETWEEN_REPOS=10
  SLEEP_BETWEEN_REPOS_FILES=10
  RETRY_SLEEP=180
  MAX_RETRIES=5
  SHALLOW_IMPORT=true
  KEEP_TEMP=false

Examples:
  ./scripts/import_all_repos_conservative.sh
  ./scripts/import_all_repos_conservative.sh --exact
  MAX_RETRIES=8 RETRY_SLEEP=300 ./scripts/import_all_repos_conservative.sh
EOF
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown parameter: $1${NC}"
            exit 1
            ;;
    esac
    shift
done

# -------------------------
# Dependency checks
# -------------------------
if ! command -v vcs >/dev/null 2>&1; then
    echo -e "${RED}ERROR: 'vcs' command not found.${NC}"
    echo "Install vcstool first, for example:"
    echo "  sudo apt install python3-vcstool"
    exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo -e "${RED}ERROR: python3 command not found.${NC}"
    exit 1
fi

if [[ ! -d "$REPOS_DIR" ]]; then
    echo -e "${RED}ERROR: repos directory not found: $REPOS_DIR${NC}"
    exit 1
fi

mkdir -p "$WORKSPACES_DIR"

# -------------------------
# Conservative Git settings
# -------------------------
# These are inherited by git commands spawned by `vcs import`.
# They reduce parallelism and avoid some HTTP/2/network burst issues.
export GIT_CONFIG_COUNT=9
export GIT_CONFIG_KEY_0=http.maxRequests
export GIT_CONFIG_VALUE_0=1
export GIT_CONFIG_KEY_1=http.lowSpeedLimit
export GIT_CONFIG_VALUE_1=1000
export GIT_CONFIG_KEY_2=http.lowSpeedTime
export GIT_CONFIG_VALUE_2=600
export GIT_CONFIG_KEY_3=http.version
export GIT_CONFIG_VALUE_3=HTTP/1.1
export GIT_CONFIG_KEY_4=fetch.parallel
export GIT_CONFIG_VALUE_4=1
export GIT_CONFIG_KEY_5=submodule.fetchJobs
export GIT_CONFIG_VALUE_5=1
export GIT_CONFIG_KEY_6=pack.threads
export GIT_CONFIG_VALUE_6=1
export GIT_CONFIG_KEY_7=index.threads
export GIT_CONFIG_VALUE_7=1
export GIT_CONFIG_KEY_8=core.compression
export GIT_CONFIG_VALUE_8=1

# Conservative SSH defaults, but do not overwrite a user's existing SSH command.
if [[ -z "${GIT_SSH_COMMAND:-}" ]]; then
    export GIT_SSH_COMMAND="ssh -o ConnectTimeout=30 -o ConnectionAttempts=3 -o ServerAliveInterval=30 -o ServerAliveCountMax=4"
fi

# Detect vcstool options.
VCS_SUPPORTS_WORKERS=false
VCS_SUPPORTS_SHALLOW=false
if vcs import --help 2>&1 | grep -q -- '--workers'; then
    VCS_SUPPORTS_WORKERS=true
fi
if vcs import --help 2>&1 | grep -q -- '--shallow'; then
    VCS_SUPPORTS_SHALLOW=true
fi

TMP_ROOT="$(mktemp -d)"
cleanup() {
    if [[ "$KEEP_TEMP" == "true" ]]; then
        echo -e "${YELLOW}Keeping temporary files at: $TMP_ROOT${NC}"
    else
        rm -rf "$TMP_ROOT"
    fi
}
trap cleanup EXIT

is_probably_commit_sha() {
    local value="${1:-}"
    [[ "$value" =~ ^[0-9a-fA-F]{7,40}$ ]]
}

sleep_with_message() {
    local seconds="$1"
    local reason="$2"

    if (( seconds <= 0 )); then
        return 0
    fi

    echo -e "${BLUE}Sleeping ${seconds}s ${reason}...${NC}"
    sleep "$seconds"
}

run_with_retries() {
    local attempt=1

    while true; do
        if "$@"; then
            return 0
        fi

        if (( attempt >= MAX_RETRIES )); then
            echo -e "${RED}ERROR: command failed after $MAX_RETRIES attempts.${NC}"
            return 1
        fi

        echo
        echo -e "${YELLOW}Command failed. Waiting ${RETRY_SLEEP}s before retry $((attempt + 1))/$MAX_RETRIES...${NC}"
        sleep "$RETRY_SLEEP"
        attempt=$((attempt + 1))
    done
}

split_repos_file() {
    local repos_file="$1"
    local output_dir="$2"
    local manifest_file="$3"

    mkdir -p "$output_dir"

    python3 - "$repos_file" "$output_dir" "$manifest_file" <<'PY'
import json
import pathlib
import re
import sys

repos_file = pathlib.Path(sys.argv[1])
output_dir = pathlib.Path(sys.argv[2])
manifest_file = pathlib.Path(sys.argv[3])

def unquote(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in ("'", '"'):
        return value[1:-1]
    return value

def sanitize_filename(value: str) -> str:
    value = re.sub(r"[^A-Za-z0-9_.-]+", "_", value.strip())
    value = value.strip("._")
    return value[:80] or "repo"

repos = []
current = None
inside_repositories = False

with repos_file.open("r", encoding="utf-8") as f:
    for raw in f:
        stripped = raw.strip()

        if not stripped or stripped.startswith("#"):
            continue

        if stripped == "repositories:":
            inside_repositories = True
            continue

        if not inside_repositories:
            continue

        # Repository path line: exactly two spaces, then a YAML key.
        if raw.startswith("  ") and not raw.startswith("    ") and stripped.endswith(":"):
            repo_name = unquote(stripped[:-1])
            current = {"name": repo_name, "fields": {}}
            repos.append(current)
            continue

        # Repository field line: exactly four spaces, key: value.
        if current is not None and raw.startswith("    ") and ":" in stripped:
            key, value = stripped.split(":", 1)
            current["fields"][key.strip()] = unquote(value.strip())
            continue

if not repos:
    print(f"ERROR: no repositories found in {repos_file}", file=sys.stderr)
    sys.exit(2)

sep = "\x1f"

with manifest_file.open("w", encoding="utf-8") as manifest:
    for index, repo in enumerate(repos, start=1):
        name = repo["name"]
        fields = dict(repo["fields"])

        filename = f"{index:04d}_{sanitize_filename(name)}.repos"
        one_repo_file = output_dir / filename

        preferred_order = ["type", "url", "version"]
        ordered_keys = [k for k in preferred_order if k in fields]
        ordered_keys += [k for k in fields.keys() if k not in ordered_keys]

        with one_repo_file.open("w", encoding="utf-8") as out:
            out.write("repositories:\n")
            out.write(f"  {json.dumps(name)}:\n")
            for key in ordered_keys:
                out.write(f"    {key}: {json.dumps(fields[key])}\n")

        repo_type = fields.get("type", "")
        repo_version = fields.get("version", "")

        manifest.write(sep.join([
            str(index),
            name,
            repo_type,
            repo_version,
            str(one_repo_file),
        ]) + "\n")
PY
}

vcs_import_one_repo() {
    local target_ws="$1"
    local one_repo_file="$2"
    local repo_type="$3"
    local repo_version="$4"

    local args=(vcs import --recursive)

    if [[ "$VCS_SUPPORTS_WORKERS" == "true" ]]; then
        args+=(--workers 1)
    fi

    if [[ "$SHALLOW_IMPORT" == "true" && "$VCS_SUPPORTS_SHALLOW" == "true" && "$repo_type" == "git" ]]; then
        if ! is_probably_commit_sha "$repo_version"; then
            args+=(--shallow)
        fi
    fi

    args+=("$target_ws")

    if [[ "$DRY_RUN" == "true" ]]; then
        echo "[DRY RUN] ${args[*]} < $one_repo_file"
        return 0
    fi

    "${args[@]}" < "$one_repo_file"
}

import_repos_file_conservatively() {
    local repos_file="$1"
    local target_ws="$2"
    local label="$3"

    if [[ ! -f "$repos_file" ]]; then
        echo -e "${RED}ERROR: repos file not found: $repos_file${NC}"
        exit 1
    fi

    mkdir -p "$target_ws"

    local split_dir="$TMP_ROOT/$(basename "$repos_file").split"
    local manifest_file="$split_dir/manifest.txt"

    split_repos_file "$repos_file" "$split_dir" "$manifest_file"

    local repo_count
    repo_count="$(wc -l < "$manifest_file" | tr -d ' ')"

    echo
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}Importing .repos file conservatively${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo "Label:           $label"
    echo "Repos file:      $repos_file"
    echo "Target folder:   $target_ws"
    echo "Repositories:    $repo_count"
    echo "vcs workers:     $([[ "$VCS_SUPPORTS_WORKERS" == "true" ]] && echo 1 || echo "not supported by this vcstool")"
    echo "shallow import:  $SHALLOW_IMPORT$([[ "$VCS_SUPPORTS_SHALLOW" == "true" ]] || echo " (not supported by this vcstool)")"
    echo

    local US=$'\037'
    local repo_index repo_name repo_type repo_version one_repo_file

    while IFS="$US" read -r repo_index repo_name repo_type repo_version one_repo_file; do
        echo -e "${YELLOW}----------------------------------------${NC}"
        echo -e "${YELLOW}[$repo_index/$repo_count] $repo_name${NC}"
        echo "Type:       ${repo_type:-unknown}"
        echo "Version:    ${repo_version:-not specified}"
        echo "Workspace:  $target_ws"
        echo

        run_with_retries vcs_import_one_repo "$target_ws" "$one_repo_file" "$repo_type" "$repo_version"

        echo -e "${GREEN}✓ Finished: $repo_name${NC}"
        sleep_with_message "$SLEEP_BETWEEN_REPOS" "before the next repository"
        echo
    done < "$manifest_file"

    echo -e "${GREEN}✓ Finished .repos file: $repos_file${NC}"
}

apply_mmwave_patch_if_needed() {
    local mmwave_repos="$REPOS_DIR/ws_mmwave_ti_ros.repos"
    local mmwave_ws="$WORKSPACES_DIR/ws_mmwave_ti_ros"
    local mmwave_src="$mmwave_ws/src/mmwave_ti_ros"
    local mmwave_patch="$REPOS_DIR/patches/ws_mmwave_ti_ros.patch"

    if [[ ! -f "$mmwave_repos" || ! -f "$mmwave_patch" || ! -d "$mmwave_src" ]]; then
        return 0
    fi

    local abs_patch
    abs_patch="$(cd "$(dirname "$mmwave_patch")" && pwd)/$(basename "$mmwave_patch")"

    echo -e "${YELLOW}Applying mmwave_ti_ros patch if needed...${NC}"

    if git -C "$mmwave_src" apply --check "$abs_patch" >/dev/null 2>&1; then
        git -C "$mmwave_src" apply "$abs_patch"
        echo -e "${GREEN}✓ Successfully applied mmwave_ti_ros patch${NC}"
    elif git -C "$mmwave_src" apply --reverse --check "$abs_patch" >/dev/null 2>&1; then
        echo -e "${GREEN}✓ mmwave_ti_ros patch already applied; skipping${NC}"
    else
        echo -e "${RED}✗ Failed to apply mmwave_ti_ros patch${NC}"
        echo "Patch file: $abs_patch"
        echo "Source dir: $mmwave_src"
        exit 1
    fi
}

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Very conservative UAS repos importer${NC}"
echo -e "${GREEN}========================================${NC}"
echo "Repository root:             $UAS_REPO_ROOT"
echo "Repos dir:                   $REPOS_DIR"
echo "Workspaces dir:              $WORKSPACES_DIR"
echo "Exact mode:                  $USE_EXACT"
echo "Sleep between repositories:  ${SLEEP_BETWEEN_REPOS}s"
echo "Sleep between .repos files:  ${SLEEP_BETWEEN_REPOS_FILES}s"
echo "Retry sleep:                 ${RETRY_SLEEP}s"
echo "Max retries:                 $MAX_RETRIES"
echo "Shallow import:              $SHALLOW_IMPORT"
echo "Dry run:                     $DRY_RUN"
echo

# -------------------------
# 1) Import robot_bringup first, like the original script.
# -------------------------
if [[ "$USE_EXACT" == "true" ]]; then
    robot_bringup_repos_file="$REPOS_DIR/robot_bringup_exact.repos"
else
    robot_bringup_repos_file="$REPOS_DIR/robot_bringup.repos"
fi

import_repos_file_conservatively "$robot_bringup_repos_file" "$WORKSPACES_DIR" "robot_bringup"
sleep_with_message "$SLEEP_BETWEEN_REPOS_FILES" "before the next .repos file"

# -------------------------
# 2) Import every ws*.repos file, one repo at a time.
# -------------------------
if [[ "$USE_EXACT" == "true" ]]; then
    mapfile -t repos_files < <(find "$REPOS_DIR" -name "ws*exact.repos" -type f | sort)
    suffix="_exact.repos"
else
    mapfile -t repos_files < <(find "$REPOS_DIR" -name "ws*.repos" ! -name "*exact.repos" -type f | sort)
    suffix=".repos"
fi

if [[ "${#repos_files[@]}" -eq 0 ]]; then
    echo -e "${YELLOW}Warning: no$([[ "$USE_EXACT" == "true" ]] && echo " exact") ws*.repos files found in $REPOS_DIR${NC}"
else
    echo -e "${GREEN}Found ${#repos_files[@]} workspace .repos files:${NC}"
    printf '  %s\n' "${repos_files[@]}"
    echo

    for repos_file in "${repos_files[@]}"; do
        ws_name="$(basename "$repos_file" "$suffix")"
        ws="$WORKSPACES_DIR/$ws_name"

        import_repos_file_conservatively "$repos_file" "$ws" "$ws_name"
        sleep_with_message "$SLEEP_BETWEEN_REPOS_FILES" "before the next .repos file"
    done
fi

# -------------------------
# 3) Keep original post-import patch behavior, but make it rerun-safe.
# -------------------------
apply_mmwave_patch_if_needed

echo
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}All repos files imported successfully.${NC}"
echo -e "${GREEN}========================================${NC}"
echo "Workspaces directory: $WORKSPACES_DIR"
