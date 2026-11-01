# git-manager

`git-manager` is a small Bash utility for creating, linking, renaming, listing, verifying, and deleting GitHub repositories from a local folder.

## Script

- `push-github-repo.sh` is the single entry point
- It expects a GitHub personal access token with repo permissions
- It uses the GitHub REST API plus local `git`

## Requirements

- `bash`
- `git`
- `curl`
- `python3`

## Setup

1. Create the config file:

```bash
./push-github-repo.sh init-config
```

2. Edit `~/.config/github-repo-manager/config.env` and set:

- `GITHUB_TOKEN`
- `GITHUB_OWNER`
- `GITHUB_OWNER_TYPE` (`user` or `org`)
- `DEFAULT_VISIBILITY`
- `DEFAULT_BRANCH`

Instead of storing the token in the config, set `GITHUB_TOKEN_FILE` to a
readable token file. The token is used for API and Git authentication but is
never written into the remote URL.

3. Make sure the script is executable:

```bash
chmod +x push-github-repo.sh
```

## Commands

```bash
./push-github-repo.sh list
./push-github-repo.sh create /home/user/github/myapp myapp private
./push-github-repo.sh push /home/user/github/myapp
./push-github-repo.sh rename /home/user/github/myapp myapp-new
./push-github-repo.sh sync-name /home/user/github/myapp
./push-github-repo.sh private myapp
./push-github-repo.sh verify myapp
./push-github-repo.sh delete myapp --yes
```

Local git and browsing:

```bash
./push-github-repo.sh clone myapp /home/user/github/myapp
./push-github-repo.sh clone octocat/Hello-World ~/src/hello test
./push-github-repo.sh pull /home/user/github/myapp
./push-github-repo.sh pull /home/user/github/myapp main --rebase
./push-github-repo.sh fetch /home/user/github/myapp
./push-github-repo.sh status /home/user/github/myapp
./push-github-repo.sh branches /home/user/github/myapp   # local + remote-tracking refs
./push-github-repo.sh branches myapp                     # queried from GitHub
./push-github-repo.sh tags cli/cli
./push-github-repo.sh log myapp 10 main
./push-github-repo.sh releases cli/cli
```

## Behavior

- `create` ensures the repo exists and points the local directory at the GitHub remote
- `push` ensures the repo exists, sets `origin`, and pushes the current branch
- `rename` renames the remote repo and updates local `origin`
- `sync-name` renames the remote repo to match the local folder name
- `private` changes an existing repository to private
- `verify` prints the repository identity, visibility, and URL
- `delete` asks for confirmation unless `--yes` is passed
- `clone` accepts a repo name (under `GITHUB_OWNER`), `owner/repo`, or any Git URL, plus an optional target dir and branch
- `pull` is fast-forward only by default; pass `--rebase` to rebase local commits instead
- `fetch` fetches `origin` with `--prune --tags`
- `status` shows origin, last commit, ahead/behind, and changed files
- `branches`, `tags`, and `log` read local refs when given a Git work tree path, otherwise they query the GitHub API (all pages)
- `releases` lists GitHub releases with draft/prerelease flags
- `clone`, `pull`, `fetch`, and the local forms of `branches`/`tags`/`log` work without a config file for public repos; the token is only handed to Git for `https://github.com/` remotes

## Notes

- The tool initializes a local Git repository if the folder is not already a repo.
- `push` requires at least one commit before it can push.
- If `origin` already exists, the script tries to reuse the owner/repo name from that remote when it can parse it.

## Android Repo Repair Commands

Commands requested during the Graphene Plus/Zero source work:

```bash
cd /home/user/Downloads/codex/github/graphene-plus/android-source
repo init -u https://android.googlesource.com/platform/manifest -b android-12.1.0_r26
mkdir -p .repo/local_manifests
cp /home/user/Downloads/codex/github/graphene-plus/manifests/graphene-plus-android12.1.xml .repo/local_manifests/graphene-plus-android12.1.xml
REPO_JOBS=4 repo sync -c -j4 frameworks/base
```

Retry if the targeted sync stalls:

```bash
cd /home/user/Downloads/codex/github/graphene-plus/android-source
repo sync -c -j1 --force-sync --no-clone-bundle --no-tags frameworks/base
```

## Config File Example

```bash
GITHUB_TOKEN="ghp_your_token_here"
GITHUB_OWNER="your-account"
GITHUB_OWNER_TYPE="user"
DEFAULT_VISIBILITY="public"
DEFAULT_BRANCH="main"
```
