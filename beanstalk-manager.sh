#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="${0##*/}"
CONFIG_FILE="${BEANSTALK_REPO_CONFIG:-$HOME/.config/git-repo-manager/beanstalk-config.env}"
LEGACY_CONFIG_FILE="$HOME/.config/beanstalk-repo-manager/config.env"
DEFAULT_BRANCH_FALLBACK="main"
ASSUME_YES=0
ASKPASS_FILE=""
TMP_PATHS=()

cleanup() {
  if [[ -n "${ASKPASS_FILE}" && -f "${ASKPASS_FILE}" ]]; then
    rm -f "${ASKPASS_FILE}"
  fi
  if [[ ${#TMP_PATHS[@]} -gt 0 ]]; then
    rm -rf "${TMP_PATHS[@]}"
  fi
}
trap cleanup EXIT

err() {
  printf '%s\n' "$*" >&2
}

die() {
  err "$*"
  exit 1
}

# Print the command about to run, shell-quoted, to stderr so piped output
# stays clean. Git calls that authenticate show the askpass helper too.
show_cmd() {
  local line="" arg

  if [[ "$1" == "git" && -n "${ASKPASS_FILE}" ]]; then
    line=" GIT_ASKPASS=<token-helper>"
  fi
  for arg in "$@"; do
    if [[ "$arg" =~ ^[A-Za-z0-9_./:=@%+,-]+$ ]]; then
      line+=" $arg"
    else
      line+=" '${arg//\'/\'\\\'\'}'"
    fi
  done
  printf '$%s\n' "$line" >&2
}

run() {
  show_cmd "$@"
  "$@"
}

usage() {
  cat <<USAGE
Beanstalk repo manager

Config:
  init-config [path]      Write a config template and exit.
  Config file defaults to ~/.config/git-repo-manager/beanstalk-config.env
  (override with BEANSTALK_REPO_CONFIG=/path/to/file)

Commands:
  list                    List repos for the configured owner.
  create <dir> [repo] [visibility]
                          Create a repo and point a local folder at it.
  push <dir> [repo] [branch] [visibility]
                          Ensure repo exists, point the local folder at it, and push.
  rename <dir> <new-repo>  Rename the Beanstalk repo and sync local origin.
  sync-name <dir>         Rename the Beanstalk repo to match the local folder name.
  private <repo>           Set an existing repository to private.
  verify <repo>            Show repository name, visibility, and URL.
  delete <repo> [--yes]    Delete a Beanstalk repo.

Local git:
  clone <repo|owner/repo|url> [dir] [branch]
                          Clone a repo (token is used for private Beanstalk HTTPS repos).
  pull <dir> [branch] [--rebase]
                          Pull from origin (fast-forward only unless --rebase).
  fetch <dir>             Fetch origin, prune deleted branches, and fetch tags.
  status <dir>            Show branch, ahead/behind, and working tree changes.

Browse (a git work tree path reads local refs, anything else queries Beanstalk):
  branches <dir|repo>     List branches (current/default marked with *).
  tags <dir|repo>         List tags, newest first.
  log <dir|repo> [count] [branch]
                          Show recent commits (default 20).
  releases <repo>         List Beanstalk releases.

  <repo> is a name under BEANSTALK_OWNER or an explicit owner/repo.

Examples:
  ${SCRIPT_NAME} init-config
  ${SCRIPT_NAME} list
  ${SCRIPT_NAME} create /home/user/beanstalk/myapp myapp private
  ${SCRIPT_NAME} push /home/user/beanstalk/myapp
  ${SCRIPT_NAME} rename /home/user/beanstalk/myapp myapp-new
  ${SCRIPT_NAME} sync-name /home/user/beanstalk/myapp
  ${SCRIPT_NAME} private myapp
  ${SCRIPT_NAME} verify myapp
  ${SCRIPT_NAME} delete myapp --yes
  ${SCRIPT_NAME} clone myapp /home/user/beanstalk/myapp
  ${SCRIPT_NAME} clone torvalds/linux
  ${SCRIPT_NAME} pull /home/user/beanstalk/myapp
  ${SCRIPT_NAME} branches /home/user/beanstalk/myapp
  ${SCRIPT_NAME} tags octocat/Hello-World
  ${SCRIPT_NAME} log myapp 10 main
USAGE
}

write_config_template() {
  local path="${1:-$CONFIG_FILE}"
  mkdir -p "$(dirname "$path")"
  cat >"$path" <<'CFG'
# Beanstalk repo manager config
# Fill these values in before using the script.

# Personal access token with repo permissions.
BEANSTALK_TOKEN=""

# Optional token file. Used when BEANSTALK_TOKEN is empty.
# BEANSTALK_TOKEN_FILE="/home/user/Downloads/codex/beanstalk_token.txt"

# Beanstalk account or organization name.
BEANSTALK_OWNER="nano-rex"

# user = /user/repos API, org = /orgs/<org>/repos API.
BEANSTALK_OWNER_TYPE="user"

# Default visibility for new repositories.
DEFAULT_VISIBILITY="public"

# Default branch name used when initializing a local git repo.
DEFAULT_BRANCH="main"
CFG
  chmod 600 "$path" 2>/dev/null || true
  printf 'Wrote config template to %s\n' "$path"
}

# Fall back to the pre-rename config location until it has been moved.
use_legacy_config_if_needed() {
  if [[ -z "${BEANSTALK_REPO_CONFIG:-}" && ! -f "$CONFIG_FILE" && -f "$LEGACY_CONFIG_FILE" ]]; then
    err "Note: using legacy config $LEGACY_CONFIG_FILE; move it to $CONFIG_FILE"
    CONFIG_FILE="$LEGACY_CONFIG_FILE"
  fi
}

load_config() {
  use_legacy_config_if_needed
  [[ -f "$CONFIG_FILE" ]] || die "Missing config: $CONFIG_FILE. Run '$SCRIPT_NAME init-config'."
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
  if [[ -z "${BEANSTALK_TOKEN:-}" && -n "${BEANSTALK_TOKEN_FILE:-}" ]]; then
    [[ -r "$BEANSTALK_TOKEN_FILE" ]] || die "Token file is not readable: $BEANSTALK_TOKEN_FILE"
    BEANSTALK_TOKEN="$(tr -d '\r\n' < "$BEANSTALK_TOKEN_FILE")"
  fi
  : "${BEANSTALK_TOKEN:?BEANSTALK_TOKEN or BEANSTALK_TOKEN_FILE is required in $CONFIG_FILE}"
  : "${BEANSTALK_OWNER:?BEANSTALK_OWNER is required in $CONFIG_FILE}"
  BEANSTALK_OWNER_TYPE="${BEANSTALK_OWNER_TYPE:-user}"
  DEFAULT_VISIBILITY="${DEFAULT_VISIBILITY:-public}"
  DEFAULT_BRANCH="${DEFAULT_BRANCH:-$DEFAULT_BRANCH_FALLBACK}"
}

require_commands() {
  local cmd

  for cmd in git curl python3; do
    command -v "$cmd" >/dev/null 2>&1 || die "Missing required command: $cmd"
  done
}

make_askpass() {
  ASKPASS_FILE="$(mktemp)"
  python3 - "$ASKPASS_FILE" "$BEANSTALK_TOKEN" <<'PY'
import pathlib
import shlex
import sys

path = pathlib.Path(sys.argv[1])
token = sys.argv[2]
quoted = shlex.quote(token)
path.write_text(
    "#!/usr/bin/env bash\n"
    "case \"$1\" in\n"
    "  *Username*) printf '%s\\n' 'x-access-token' ;;\n"
    f"  *) printf '%s\\n' {quoted} ;;\n"
    "esac\n",
    encoding="utf-8",
)
path.chmod(0o700)
PY
}

git_env() {
  make_askpass
  export GIT_ASKPASS="$ASKPASS_FILE"
  export GIT_TERMINAL_PROMPT=0
}

gh_api() {
  local method="$1"
  local url="$2"
  local data="${3:-}"

  local args=(
    -fsSL
    -H "Authorization: Bearer ${BEANSTALK_TOKEN}"
    -H "Accept: application/vnd.beanstalk+json"
    -H "X-Beanstalk-Api-Version: 2022-11-28"
  )

  if [[ "$method" != "GET" ]]; then
    args+=( -X "$method" -H "Content-Type: application/json" -d "$data" )
  fi

  local -a shown=( curl -X "$method" -H 'Authorization: Bearer ***' )
  [[ "$method" != "GET" ]] && shown+=( -d "$data" )
  show_cmd "${shown[@]}" "$url"
  curl "${args[@]}" "$url"
}

repo_api_base() {
  printf 'https://api.beanstalk.com/repos/%s' "$BEANSTALK_OWNER"
}

repo_api_url() {
  printf '%s/%s\n' "$(repo_api_base)" "$1"
}

list_api_url() {
  if [[ "$BEANSTALK_OWNER_TYPE" == "org" ]]; then
    printf 'https://api.beanstalk.com/orgs/%s/repos?per_page=100&type=all&sort=updated&page=%s' "$BEANSTALK_OWNER" "$1"
  else
    printf 'https://api.beanstalk.com/user/repos?per_page=100&affiliation=owner&sort=updated&page=%s' "$1"
  fi
}

repo_exists() {
  local repo_name="$1"
  gh_api GET "$(repo_api_base)/${repo_name}" >/dev/null 2>&1
}

create_repo() {
  local repo_name="$1"
  local visibility="${2:-$DEFAULT_VISIBILITY}"
  local endpoint data

  if [[ "$BEANSTALK_OWNER_TYPE" == "org" ]]; then
    endpoint="https://api.beanstalk.com/orgs/${BEANSTALK_OWNER}/repos"
  else
    endpoint="https://api.beanstalk.com/user/repos"
  fi

  data="$(python3 - "$repo_name" "$visibility" <<'PY'
import json
import sys

repo_name = sys.argv[1]
visibility = sys.argv[2]
print(json.dumps({
    "name": repo_name,
    "private": visibility == "private",
    "auto_init": False,
}))
PY
)"

  gh_api POST "$endpoint" "$data" >/dev/null
  printf 'Created %s/%s (%s)\n' "$BEANSTALK_OWNER" "$repo_name" "$visibility"
}

ensure_repo_exists() {
  local repo_name="$1"
  local visibility="${2:-$DEFAULT_VISIBILITY}"

  if repo_exists "$repo_name"; then
    return 0
  fi

  create_repo "$repo_name" "$visibility"
}

ensure_local_git_repo() {
  local dir="$1"
  local branch="${2:-$DEFAULT_BRANCH}"

  if ! git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    run git -C "$dir" init -b "$branch" >/dev/null
  fi
}

set_origin_url() {
  local dir="$1"
  local owner="$2"
  local repo_name="$3"
  local url="https://beanstalk.com/${owner}/${repo_name}.git"

  if git -C "$dir" remote get-url origin >/dev/null 2>&1; then
    run git -C "$dir" remote set-url origin "$url"
  else
    run git -C "$dir" remote add origin "$url"
  fi
}

current_branch() {
  local dir="$1"
  local branch

  branch="$(git -C "$dir" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
  if [[ -z "$branch" || "$branch" == "HEAD" ]]; then
    branch="$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  fi
  if [[ -z "$branch" || "$branch" == "HEAD" ]]; then
    branch="$DEFAULT_BRANCH"
  fi
  printf '%s\n' "$branch"
}

repo_name_from_dir() {
  local dir="$1"
  basename "${dir%/}"
}

repo_from_origin() {
  local origin="$1"
  python3 - "$origin" <<'PY'
import re
import sys

origin = sys.argv[1]
patterns = [
    r'^git@beanstalk\.com:(?P<owner>[^/]+)/(?P<repo>[^/]+?)(?:\.git)?$',
    r'^https?://(?:[^@/]+@)?beanstalk\.com/(?P<owner>[^/]+)/(?P<repo>[^/]+?)(?:\.git)?$',
]
for pattern in patterns:
    match = re.match(pattern, origin)
    if match:
        print(match.group('owner'))
        print(match.group('repo'))
        break
else:
    sys.exit(1)
PY
}

local_repo_owner_and_name() {
  local dir="$1"
  local origin owner repo_name
  local -a parsed

  if origin="$(git -C "$dir" remote get-url origin 2>/dev/null)"; then
    if mapfile -t parsed < <(repo_from_origin "$origin"); then
      owner="${parsed[0]}"
      repo_name="${parsed[1]}"
      printf '%s\t%s\n' "$owner" "$repo_name"
      return 0
    fi
  fi

  printf '%s\t%s\n' "$BEANSTALK_OWNER" "$(repo_name_from_dir "$dir")"
}

push_local_repo() {
  local dir="$1"
  local repo_name="${2:-}"
  local branch="${3:-}"
  local visibility="${4:-$DEFAULT_VISIBILITY}"
  local owner="$BEANSTALK_OWNER"

  [[ -d "$dir" ]] || die "Local folder not found: $dir"
  ensure_local_git_repo "$dir" "$DEFAULT_BRANCH"

  if [[ -z "$repo_name" ]]; then
    repo_name="$(local_repo_owner_and_name "$dir" | cut -f2)"
  fi
  if [[ -z "$branch" ]]; then
    branch="$(current_branch "$dir")"
  fi

  ensure_repo_exists "$repo_name" "$visibility"
  set_origin_url "$dir" "$owner" "$repo_name"

  if ! git -C "$dir" rev-parse --verify HEAD >/dev/null 2>&1; then
    die "${dir} has no commits yet. Create at least one commit before pushing."
  fi

  git_env
  run git -C "$dir" push -u origin "$branch"
}

create_local_repo() {
  local dir="$1"
  local repo_name="${2:-}"
  local visibility="${3:-$DEFAULT_VISIBILITY}"
  local owner="$BEANSTALK_OWNER"

  [[ -d "$dir" ]] || die "Local folder not found: $dir"
  ensure_local_git_repo "$dir" "$DEFAULT_BRANCH"

  if [[ -z "$repo_name" ]]; then
    repo_name="$(repo_name_from_dir "$dir")"
  fi

  ensure_repo_exists "$repo_name" "$visibility"
  set_origin_url "$dir" "$owner" "$repo_name"
  printf 'Pointed %s at %s/%s\n' "$dir" "$owner" "$repo_name"
}

rename_remote_repo() {
  local dir="$1"
  local new_repo_name="$2"
  local owner old_repo
  local origin
  local -a parsed

  [[ -d "$dir" ]] || die "Local folder not found: $dir"
  ensure_local_git_repo "$dir" "$DEFAULT_BRANCH"

  if origin="$(git -C "$dir" remote get-url origin 2>/dev/null)"; then
    if mapfile -t parsed < <(repo_from_origin "$origin"); then
      owner="${parsed[0]}"
      old_repo="${parsed[1]}"
    else
      owner="$BEANSTALK_OWNER"
      old_repo="$(repo_name_from_dir "$dir")"
    fi
  else
    owner="$BEANSTALK_OWNER"
    old_repo="$(repo_name_from_dir "$dir")"
  fi

  if [[ "$old_repo" == "$new_repo_name" ]]; then
    printf 'Repo already named %s\n' "$new_repo_name"
    set_origin_url "$dir" "$owner" "$new_repo_name"
    return 0
  fi

  local data
  data="$(python3 - "$new_repo_name" <<'PY'
import json
import sys

print(json.dumps({"name": sys.argv[1]}))
PY
)"

  gh_api PATCH "$(repo_api_base)/${old_repo}" "$data" >/dev/null
  set_origin_url "$dir" "$owner" "$new_repo_name"
  printf 'Renamed %s/%s -> %s/%s\n' "$owner" "$old_repo" "$owner" "$new_repo_name"
}

set_private_repo() {
  local repo_name="$1"

  gh_api PATCH "$(repo_api_url "$repo_name")" '{"private":true}' >/dev/null
  printf 'Set %s/%s to private\n' "$BEANSTALK_OWNER" "$repo_name"
}

verify_repo() {
  local repo_name="$1"

  gh_api GET "$(repo_api_url "$repo_name")" | python3 -c '
import json
import sys

data = json.load(sys.stdin)
for key in ("full_name", "private", "html_url"):
    print(f"{key} {json.dumps(data[key])}")
'
}

sync_name_from_dir() {
  local dir="$1"
  rename_remote_repo "$dir" "$(repo_name_from_dir "$dir")"
}

delete_repo() {
  local repo_name="$1"

  if [[ "$ASSUME_YES" != "1" ]]; then
    printf 'Type %s to confirm deletion: ' "$repo_name" >&2
    local confirm
    read -r confirm
    [[ "$confirm" == "$repo_name" ]] || die "Deletion cancelled"
  fi

  gh_api DELETE "$(repo_api_base)/${repo_name}" >/dev/null
  printf 'Deleted %s/%s\n' "$BEANSTALK_OWNER" "$repo_name"
}

list_repos() {
  local page=1
  local total=0
  local url count tmp

  printf '%-32s %-8s %-16s %s\n' "REPO" "VIS" "BRANCH" "URL"

  while :; do
    url="$(list_api_url "$page")"
    tmp="$(mktemp)"
    gh_api GET "$url" >"$tmp"

    count="$(python3 - "$tmp" <<'PY'
import json
import sys

with open(sys.argv[1], encoding='utf-8') as handle:
    data = json.load(handle)
print(len(data))
PY
)"

    if [[ "$count" == "0" ]]; then
      rm -f "$tmp"
      break
    fi

    python3 - "$tmp" <<'PY'
import json
import sys

with open(sys.argv[1], encoding='utf-8') as handle:
    data = json.load(handle)

for repo in data:
    visibility = 'private' if repo.get('private') else 'public'
    print(f"{repo.get('name', '')}\t{visibility}\t{repo.get('default_branch', '')}\t{repo.get('html_url', '')}")
PY

    total=$((total + count))
    rm -f "$tmp"
    [[ "$count" -lt 100 ]] && break
    page=$((page + 1))
  done

  printf 'Total: %s\n' "$total"
}

# Like load_config, but a missing config or token is fine: public repos and
# SSH remotes work without one.
try_load_config() {
  use_legacy_config_if_needed
  if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
  fi
  if [[ -z "${BEANSTALK_TOKEN:-}" && -n "${BEANSTALK_TOKEN_FILE:-}" && -r "${BEANSTALK_TOKEN_FILE}" ]]; then
    BEANSTALK_TOKEN="$(tr -d '\r\n' < "$BEANSTALK_TOKEN_FILE")"
  fi
  BEANSTALK_TOKEN="${BEANSTALK_TOKEN:-}"
  BEANSTALK_OWNER="${BEANSTALK_OWNER:-}"
  DEFAULT_BRANCH="${DEFAULT_BRANCH:-$DEFAULT_BRANCH_FALLBACK}"
}

is_beanstalk_https_url() {
  [[ "$1" =~ ^https://([^@/]+@)?beanstalk\.com/ ]]
}

# Only hand the token to git when the remote is Beanstalk over HTTPS, so it is
# never offered to another host.
git_env_for_url() {
  if [[ -n "${BEANSTALK_TOKEN:-}" ]] && is_beanstalk_https_url "$1"; then
    git_env
  fi
}

# Turn "repo" or "owner/repo" into "owner/repo".
resolve_repo_spec() {
  local spec="$1"

  [[ "$spec" =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)?$ ]] || die "Invalid repo: $spec"
  if [[ "$spec" == */* ]]; then
    printf '%s\n' "${spec%.git}"
  else
    [[ -n "${BEANSTALK_OWNER:-}" ]] || die "BEANSTALK_OWNER is not set; use owner/repo or set it in $CONFIG_FILE"
    printf '%s/%s\n' "$BEANSTALK_OWNER" "${spec%.git}"
  fi
}

is_work_tree() {
  [[ -d "$1" ]] && git -C "$1" rev-parse --is-inside-work-tree >/dev/null 2>&1
}

require_work_tree() {
  is_work_tree "$1" || die "Not a git work tree: $1"
}

urlencode() {
  python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}

# Fetch every page of a Beanstalk list endpoint and print one merged JSON array.
gh_api_all() {
  local base="$1"
  local page=1
  local sep='?'
  local tmpdir count

  [[ "$base" == *\?* ]] && sep='&'
  tmpdir="$(mktemp -d)"
  TMP_PATHS+=( "$tmpdir" )

  while :; do
    gh_api GET "${base}${sep}per_page=100&page=${page}" >"${tmpdir}/$(printf '%05d' "$page").json"
    count="$(python3 -c 'import json, sys; print(len(json.load(open(sys.argv[1], encoding="utf-8"))))' \
      "${tmpdir}/$(printf '%05d' "$page").json")"
    [[ "$count" -lt 100 ]] && break
    page=$((page + 1))
  done

  python3 - "$tmpdir" <<'PY'
import json
import pathlib
import sys

merged = []
for path in sorted(pathlib.Path(sys.argv[1]).glob('*.json')):
    merged.extend(json.loads(path.read_text(encoding='utf-8')))
json.dump(merged, sys.stdout)
PY
}

clone_repo() {
  local source="$1"
  local dir="${2:-}"
  local branch="${3:-}"
  local url
  local -a args=( clone )

  if [[ "$source" == *://* || "$source" == git@* ]]; then
    url="$source"
  else
    url="https://beanstalk.com/$(resolve_repo_spec "$source").git"
  fi

  [[ -n "$branch" ]] && args+=( --branch "$branch" )
  args+=( "$url" )
  [[ -n "$dir" ]] && args+=( "$dir" )

  git_env_for_url "$url"
  run git "${args[@]}"
}

pull_repo() {
  local dir="$1"
  local branch="${2:-}"
  local mode="${3:---ff-only}"
  local origin

  require_work_tree "$dir"
  origin="$(git -C "$dir" remote get-url origin 2>/dev/null)" || die "${dir} has no origin remote"

  git_env_for_url "$origin"
  if [[ -n "$branch" ]]; then
    run git -C "$dir" pull "$mode" origin "$branch"
  else
    run git -C "$dir" pull "$mode"
  fi
}

fetch_repo() {
  local dir="$1"
  local origin

  require_work_tree "$dir"
  origin="$(git -C "$dir" remote get-url origin 2>/dev/null)" || die "${dir} has no origin remote"

  git_env_for_url "$origin"
  run git -C "$dir" fetch --prune --tags origin
}

status_repo() {
  local dir="$1"
  local origin

  require_work_tree "$dir"
  origin="$(git -C "$dir" remote get-url origin 2>/dev/null || printf '(none)')"
  printf 'origin  %s\n' "$origin"
  printf 'last    %s\n' "$(git -C "$dir" log -1 --format='%h %cs %s' 2>/dev/null || printf '(no commits)')"
  run git -C "$dir" status --short --branch
}

list_branches() {
  local target="$1"
  local spec default_branch

  if is_work_tree "$target"; then
    run git -C "$target" for-each-ref --sort=refname \
      --format='%(if)%(symref)%(then)%(else)%(HEAD) %(refname:short)%09%(objectname:short)%09%(committerdate:short)%09%(subject)%(end)' \
      refs/heads refs/remotes | awk 'NF' | column -t -s $'\t'
    return 0
  fi

  load_config
  spec="$(resolve_repo_spec "$target")"
  default_branch="$(gh_api GET "https://api.beanstalk.com/repos/${spec}" \
    | python3 -c 'import json, sys; print(json.load(sys.stdin).get("default_branch", ""))')"
  gh_api_all "https://api.beanstalk.com/repos/${spec}/branches" | python3 -c '
import json
import sys

default = sys.argv[1]
branches = json.load(sys.stdin)
print("  %-40s %-9s %s" % ("BRANCH", "SHA", "PROTECTED"))
for branch in branches:
    mark = "*" if branch["name"] == default else " "
    protected = "yes" if branch.get("protected") else ""
    print("%s %-40s %-9s %s" % (mark, branch["name"], branch["commit"]["sha"][:7], protected))
print("Total: %d" % len(branches))
' "$default_branch"
}

list_tags() {
  local target="$1"
  local spec

  if is_work_tree "$target"; then
    run git -C "$target" for-each-ref --sort=-creatordate \
      --format='%(refname:short)%09%(objectname:short)%09%(creatordate:short)%09%(subject)' \
      refs/tags | column -t -s $'\t'
    return 0
  fi

  load_config
  spec="$(resolve_repo_spec "$target")"
  gh_api_all "https://api.beanstalk.com/repos/${spec}/tags" | python3 -c '
import json
import sys

tags = json.load(sys.stdin)
print("%-40s %s" % ("TAG", "SHA"))
for tag in tags:
    print("%-40s %s" % (tag["name"], tag["commit"]["sha"][:7]))
print("Total: %d" % len(tags))
'
}

show_log() {
  local target="$1"
  local count="${2:-20}"
  local branch="${3:-}"
  local spec url

  [[ "$count" =~ ^[0-9]+$ && "$count" -gt 0 ]] || die "Count must be a positive number: $count"

  if is_work_tree "$target"; then
    local -a args=( log --format='%h %cs %<(16,trunc)%an %s%d' -n "$count" )
    [[ -n "$branch" ]] && args+=( "$branch" )
    run git -C "$target" "${args[@]}"
    return 0
  fi

  load_config
  spec="$(resolve_repo_spec "$target")"
  [[ "$count" -le 100 ]] || die "Beanstalk log is limited to 100 commits"
  url="https://api.beanstalk.com/repos/${spec}/commits?per_page=${count}"
  [[ -n "$branch" ]] && url+="&sha=$(urlencode "$branch")"
  gh_api GET "$url" | python3 -c '
import json
import sys

for item in json.load(sys.stdin):
    commit = item["commit"]
    author = (commit.get("author") or {}).get("name", "")[:16]
    date = (commit.get("committer") or {}).get("date", "")[:10]
    subject = commit.get("message", "").splitlines()[0] if commit.get("message") else ""
    print("%s %s %-16s %s" % (item["sha"][:7], date, author, subject))
'
}

list_releases() {
  local spec

  spec="$(resolve_repo_spec "$1")"
  gh_api_all "https://api.beanstalk.com/repos/${spec}/releases" | python3 -c '
import json
import sys

releases = json.load(sys.stdin)
print("%-24s %-10s %-16s %s" % ("TAG", "DATE", "FLAGS", "NAME"))
for rel in releases:
    flags = ",".join(f for f, on in (("draft", rel.get("draft")), ("prerelease", rel.get("prerelease"))) if on)
    date = (rel.get("published_at") or rel.get("created_at") or "")[:10]
    print("%-24s %-10s %-16s %s" % (rel.get("tag_name", ""), date, flags, rel.get("name") or ""))
print("Total: %d" % len(releases))
'
}

main() {
  local cmd="${1:-}"

  case "$cmd" in
    init-config)
      write_config_template "${2:-$CONFIG_FILE}"
      ;;
    list)
      require_commands
      load_config
      list_repos
      ;;
    create)
      require_commands
      load_config
      [[ $# -ge 2 ]] || die "Usage: $SCRIPT_NAME create <dir> [repo] [visibility]"
      create_local_repo "${2}" "${3:-}" "${4:-$DEFAULT_VISIBILITY}"
      ;;
    push)
      require_commands
      load_config
      [[ $# -ge 2 ]] || die "Usage: $SCRIPT_NAME push <dir> [repo] [branch] [visibility]"
      push_local_repo "${2}" "${3:-}" "${4:-}" "${5:-$DEFAULT_VISIBILITY}"
      ;;
    rename)
      require_commands
      load_config
      [[ $# -ge 3 ]] || die "Usage: $SCRIPT_NAME rename <dir> <new-repo>"
      rename_remote_repo "${2}" "${3}"
      ;;
    sync-name)
      require_commands
      load_config
      [[ $# -ge 2 ]] || die "Usage: $SCRIPT_NAME sync-name <dir>"
      sync_name_from_dir "${2}"
      ;;
    private)
      require_commands
      load_config
      [[ $# -eq 2 ]] || die "Usage: $SCRIPT_NAME private <repo>"
      set_private_repo "${2}"
      ;;
    verify)
      require_commands
      load_config
      [[ $# -eq 2 ]] || die "Usage: $SCRIPT_NAME verify <repo>"
      verify_repo "${2}"
      ;;
    delete)
      require_commands
      load_config
      [[ $# -ge 2 ]] || die "Usage: $SCRIPT_NAME delete <repo> [--yes]"
      if [[ "${3:-}" == "--yes" ]]; then
        ASSUME_YES=1
      fi
      delete_repo "${2}"
      ;;
    clone)
      require_commands
      try_load_config
      [[ $# -ge 2 ]] || die "Usage: $SCRIPT_NAME clone <repo|owner/repo|url> [dir] [branch]"
      clone_repo "${2}" "${3:-}" "${4:-}"
      ;;
    pull)
      require_commands
      try_load_config
      local mode="--ff-only"
      local -a rest=()
      local arg
      for arg in "${@:2}"; do
        case "$arg" in
          --rebase) mode="--rebase" ;;
          --ff-only) mode="--ff-only" ;;
          *) rest+=( "$arg" ) ;;
        esac
      done
      [[ ${#rest[@]} -ge 1 ]] || die "Usage: $SCRIPT_NAME pull <dir> [branch] [--rebase]"
      pull_repo "${rest[0]}" "${rest[1]:-}" "$mode"
      ;;
    fetch)
      require_commands
      try_load_config
      [[ $# -eq 2 ]] || die "Usage: $SCRIPT_NAME fetch <dir>"
      fetch_repo "${2}"
      ;;
    status)
      [[ $# -eq 2 ]] || die "Usage: $SCRIPT_NAME status <dir>"
      status_repo "${2}"
      ;;
    branches)
      require_commands
      try_load_config
      [[ $# -eq 2 ]] || die "Usage: $SCRIPT_NAME branches <dir|repo>"
      list_branches "${2}"
      ;;
    tags)
      require_commands
      try_load_config
      [[ $# -eq 2 ]] || die "Usage: $SCRIPT_NAME tags <dir|repo>"
      list_tags "${2}"
      ;;
    log)
      require_commands
      try_load_config
      [[ $# -ge 2 ]] || die "Usage: $SCRIPT_NAME log <dir|repo> [count] [branch]"
      show_log "${2}" "${3:-20}" "${4:-}"
      ;;
    releases)
      require_commands
      load_config
      [[ $# -eq 2 ]] || die "Usage: $SCRIPT_NAME releases <repo>"
      list_releases "${2}"
      ;;
    -h|--help|help|"")
      usage
      ;;
    *)
      die "Unknown command: $cmd"
      ;;
  esac
}

main "$@"
