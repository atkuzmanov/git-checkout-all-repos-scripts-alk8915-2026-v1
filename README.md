# GitHub repo checkout script

This project contains a small script to **clone (and optionally update) all repositories** from a GitHub user or org into a destination directory.

## Prerequisites

- `gh` (GitHub CLI)
- `git`
- `python3`

Authenticate once:

```bash
gh auth login
```

## Usage

Make it executable:

```bash
chmod +x checkout_all_github_repos.sh
```

## Two-phase workflow (export list → curate → checkout)

Export a repo list (editable) for a user/org:

```bash
./checkout_all_github_repos.sh --dest ~/code --owner my-org-or-username --export-list repos.tsv
```

Edit `repos.tsv` (delete lines you don’t want). Then checkout only those repos:

```bash
./checkout_all_github_repos.sh --dest ~/code --from-list repos.tsv --update --parallel 6
```

Notes on the list format:

- Lines starting with `#` and blank lines are ignored.
- Each line can be either:
  - `owner/name<TAB>clone_url` (what `--export-list` writes), or
  - just `owner/name` (the script will resolve the URL at runtime).

Clone all repos into `~/code` using SSH:

```bash
./checkout_all_github_repos.sh --dest ~/code
```

Clone all repos for an org/user:

```bash
./checkout_all_github_repos.sh --dest ~/code --owner my-org-or-username
```

Update existing clones (fast-forward only) and run 6 clones/pulls in parallel:

```bash
./checkout_all_github_repos.sh --dest ~/code --update --parallel 6
```

Include forks and private repos (if your `gh` auth has access):

```bash
./checkout_all_github_repos.sh --dest ~/code --include-forks --visibility all
```

See all options:

```bash
./checkout_all_github_repos.sh --help
```

## Notes

- Existing directories that **aren’t** git repos are skipped (safety).
- If you prefer HTTPS cloning, pass `--protocol https`.
- For private repos, make sure your GitHub CLI auth has permission to list/clone them.
