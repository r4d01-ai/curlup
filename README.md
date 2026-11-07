# curlup

A plain-text list of 117 developer tools, each with its official installer: the project's own `curl | sh` script or an official release download. Comes with a picker that lets you choose tools and decide, for each one, whether it installs into your home folder or system-wide.

## Usage

```bash
./curlup.sh                        # fuzzy picker (fzf), numbered menu if fzf is missing
./curlup.sh k8s                    # one category: ai lang shell editor cli infra k8s net cloud sec data mobile
./curlup.sh -m user                # home-folder installs only (hides the tools that can only install system-wide)
./curlup.sh -m system              # system-wide installs only
./curlup.sh -n go,kubectl,aws      # install by name, no menu
./curlup.sh -n go:system,helm:user # force a mode per tool
./curlup.sh -l                     # list tools with their available modes (✓ = already on PATH)
./curlup.sh -d ...                 # dry run: show the commands only
./curlup.sh -y ...                 # no prompts; tools with both modes default to user
```

The picker needs fzf 0.38 or newer. If fzf is missing or too old, it offers to install it, and if you don't answer within 5 seconds it uses the plain numbered menu instead.

The fzf picker uses a neon retro theme. Set `NO_COLOR=1` to turn the colours off.

Before each install you're asked `[y/N/v]`. `v` opens the remote script in your pager so you can read it first.

## User or system install

| Mode | Where it installs | Needs root |
|---|---|---|
| `user` | your home folder, usually `~/.local/bin` | no |
| `system` | system-wide, e.g. `/usr/local/bin`, system packages and services | yes |

- 33 tools have both modes. When you pick one, the picker asks which you want, unless `-m` or `name:mode` already decided it.
- 63 tools are user-only and 21 are system-only. System-only tools are things like docker's daemon, k3s or tailscale, which install system services by design.

## Run it with curl

1. Push this folder to GitHub as `curlup`.
2. In `curlup.sh`, set `REPO` near the top to `r4d01-ai/curlup`. The script fetches `installers.txt` from that repo.
3. Run it on any machine:

```bash
curl -fsSL https://raw.githubusercontent.com/r4d01-ai/curlup/main/curlup.sh | bash
```

Pass options after `bash -s --`:

```bash
curl -fsSL https://raw.githubusercontent.com/r4d01-ai/curlup/main/curlup.sh | bash -s -- -m user k8s
curl -fsSL https://raw.githubusercontent.com/r4d01-ai/curlup/main/curlup.sh | bash -s -- -y -n go,kubectl,aws,claude
```

Prompts, the fzf picker and installers that ask questions all read from your terminal, so the interactive mode works through the pipe. If there's no terminal, e.g. in CI or cloud-init, use `-y -n …`.

To use a fork or branch without editing the script, set `CURL_INSTALLERS_REPO=user/repo` and/or `CURL_INSTALLERS_BRANCH=dev` before `bash`, or point `-f` at any file or URL.

## Adding a tool

Add one line per install mode to `installers.txt`:

```
<name>  <category>  <user|system>  <command...>
```

- To offer both modes, add two lines with the same name.
- Columns are separated by whitespace, and everything after the mode is the command.
- Commands can use `$OS` (`linux`/`darwin`) and `$ARCH` (`amd64`/`arm64`), which `curlup.sh` sets before running them.
- Use the binary's name as `<name>` so the ✓ marker works.

## Notes

- On every push, `.github/workflows/check.yml` runs shellcheck, checks that `installers.txt` parses, and tests a dry run through `curl | bash`.

- Only official sources are used, with no third-party install services. Tools with no official curl installer or release binary (ripgrep, jq, fzf, gh…) are best installed with your OS package manager or brew.
- A few downloads are Linux-oriented, e.g. ibmcloud's script URL, and az's system mode, which installs a Debian package. On macOS, brew is usually the better choice for those.
- Go and terraform look up the latest version from their official endpoints (`go.dev/VERSION`, HashiCorp's checkpoint API) at install time.
- Piping a remote script into a shell runs whatever that server sends. Use `v` to review a script, or pin a version where the installer supports it.
