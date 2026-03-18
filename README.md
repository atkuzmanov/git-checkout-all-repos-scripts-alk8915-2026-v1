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
