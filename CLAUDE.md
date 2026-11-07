# CLAUDE.md

Project context for Claude Code.

## What this is

A GitHub-hosted picker for official curl installers of developer tools. Users run:

```bash
curl -fsSL https://raw.githubusercontent.com/<user>/<repo>/main/curlup.sh | bash
```

and choose tools to install, deciding per tool between a **user** install (home folder, no sudo) and a **system** install (system-wide, sudo).

## Files

- `installers.txt`: the tool list, one install method per line: `<name> <category> <user|system> <command...>`
  - A tool with both modes has two lines with the same name.
  - Fields are whitespace-separated, and everything after the mode is the command.
  - Commands may use `$OS` (linux|darwin) and `$ARCH` (amd64|arm64), which `curlup.sh` exports.
  - `name` should match the installed binary, so the ✓ "already installed" marker works.
- `curlup.sh`: the picker. It has fzf multi-select, falls back to a numbered menu, and supports `-n name[:mode]`, `-m user|system`, `-l`, `-d` (dry run), `-y`, `-f FILE|URL` and a category argument.
- `README.md`: user docs.
- `.github/workflows/check.yml`: CI that runs shellcheck, checks that the list parses, and does a dry run through `cat curlup.sh | bash`.

## Decisions already made (keep them)

1. **Official sources only:** each project's own install script or official release download. **No third-party installer services** (no webi.sh, jpillora/installer, eget, etc.). The user explicitly rejected webi.
2. **Both install modes where the project supports them;** the user chooses. User mode installs to `~/.local/bin` (or the tool's own home dir); system mode uses sudo and `/usr/local/bin` or system packages. Don't invent a mode the official docs don't support.
3. **Safe to pipe into bash:** the whole script is inside `main()` and is called on the last line. Installers run with stdin from `/dev/tty` (or `/dev/null`), never the piped script. Prompts use the `ask` helper, which reads `/dev/tty`. Keep these invariants.
4. When piped, `curlup.sh` downloads `installers.txt` from `REPO`/`BRANCH`, which can be overridden with `CURL_INSTALLERS_REPO` and `CURL_INSTALLERS_BRANCH`. When run from a clone, it uses the local file.
5. The developer focus includes Go, Kubernetes (`k8s` category) and cloud CLIs (aws, oci, az, gcloud, ibmcloud, scw, eksctl, hcloud, terraform…).

## Open items

- **Repo chosen: `r4d01-ai/curlup`.** `REPO` in `curlup.sh` and the README examples point there. Keep them in sync if the repo moves.
- **Commands never run end to end.** Their downloads were blocked in the original environment: go, kubectl, minikube, skaffold, aws, az, oci, terraform (its version lookup uses HashiCorp's checkpoint API `current_version` field, the least certain), flux, k3d, and most non-GitHub-hosted scripts. Smoke-test these in a disposable container in both modes.
- **Already installed for real in user mode, and working:** kind, k9s, argocd, eksctl, hcloud, krew, yt-dlp.
- **System-only tools** (no official home-folder install): brew, nix, crystal, rclone, heroku, doppler, dolt, talosctl, devbox, k3s, k0s, rke2, ollama, netdata, pihole, coolify, dokploy, zerotier-cli, ibmcloud, scw. Tailscale is in the same group: system-only, since it installs a system daemon.

## How to test

```bash
shellcheck -S warning curlup.sh
./curlup.sh -l                          # parses the list; no "Skipping malformed" lines
./curlup.sh -d -n go:system,aws,kind    # dry run
cat curlup.sh | bash -s -- -f installers.txt -d -n uv,kubectl:system   # pipe path
HOME=$(mktemp -d) ./curlup.sh -y -n kind   # real user-mode install into a throwaway home
```

To test the full curl path locally, serve the folder with `python3 -m http.server 8765` and run:

```bash
curl -fsSL http://127.0.0.1:8765/curlup.sh | INSTALLERS_URL=http://127.0.0.1:8765/installers.txt bash -s -- -l
```

## Conventions

- Bash, `set -uo pipefail`, shellcheck-clean at warning level.
- When adding a tool:
  - Verify the command against the project's official docs.
  - Add `user` and/or `system` lines.
  - Keep the columns aligned (name 15 wide, category 7, mode 7).
  - Put the tool in the matching `# ---- section ----`.
