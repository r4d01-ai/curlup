#!/usr/bin/env bash
# curlup.sh: choose tools from installers.txt and run their official installers.
# Run it straight from GitHub:
#   curl -fsSL https://raw.githubusercontent.com/r4d01-ai/curlup/main/curlup.sh | bash
#   curl -fsSL .../curlup.sh | bash -s -- -n go,kubectl,aws      # pass options after "bash -s --"
# or from a clone:  ./curlup.sh [options] [category]
#
# The whole script is wrapped in main() and called on the last line, so bash reads all of it
# before running anything. That keeps "curl | bash" safe even if an installer reads stdin, and
# means a half-downloaded script can't run.

set -uo pipefail

# ---- set this to your GitHub repo once you push it ----
REPO="${CURL_INSTALLERS_REPO:-r4d01-ai/curlup}"
BRANCH="${CURL_INSTALLERS_BRANCH:-main}"
INSTALLERS_URL="${INSTALLERS_URL:-https://raw.githubusercontent.com/$REPO/$BRANCH/installers.txt}"

usage() {
  cat <<'USAGE'
Usage: curlup.sh [options] [category]

  (no options)          interactive picker (fzf if present, numbered menu otherwise)
  CATEGORY              only show one category: ai lang shell editor cli infra k8s net cloud sec data mobile
  -m user|system        prefer that install mode; hide tools that don't have it
  -n a,b:system,c:user  install by name; append :user or :system to force a mode
  -l                    list tools and their modes (✓ = already on PATH)
  -d                    dry run: print commands, run nothing
  -y                    no prompts (tools with both modes default to user)
  -f FILE|URL           use another installers list
  -h                    this help

Tools with both a user (home folder, no sudo) and a system (system-wide, sudo) installer
ask which one you want, unless -m or name:mode decides it.

Via curl, pass options after "bash -s --":
  curl -fsSL https://raw.githubusercontent.com/<repo>/main/curlup.sh | bash -s -- -m user k8s
USAGE
  exit "${1:-0}"
}

main() {
FILE="" NAMES="" LIST=0 DRY=0 YES=0 PREF="" CATEGORY="" line="" a=""

while getopts ":f:n:m:ldyh" opt; do
  case $opt in
    f) FILE=$OPTARG ;;
    n) NAMES=$OPTARG ;;
    m) PREF=$OPTARG ;;
    l) LIST=1 ;;
    d) DRY=1 ;;
    y) YES=1 ;;
    h) usage 0 ;;
    *) usage 1 ;;
  esac
done
shift $((OPTIND - 1))
CATEGORY="${1:-}"
[[ -z $PREF || $PREF == user || $PREF == system ]] || { echo "-m must be 'user' or 'system'" >&2; exit 1; }

# Platform values that commands in installers.txt can use: $OS (linux|darwin), $ARCH (amd64|arm64)
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
case "$(uname -m)" in
  x86_64 | amd64) ARCH=amd64 ;;
  aarch64 | arm64) ARCH=arm64 ;;
  *) ARCH="$(uname -m)" ;;
esac
export OS ARCH

# --- load the list: -f FILE/URL, else installers.txt next to this script (when run from a clone), else download ---
src=${BASH_SOURCE[0]:-}
if [[ -z $FILE && -f $src && -f "$(dirname "$src")/installers.txt" ]]; then
  FILE="$(dirname "$src")/installers.txt"
fi
FILE=${FILE:-$INSTALLERS_URL}
if [[ $FILE =~ ^(https?|file):// ]]; then
  if [[ $FILE == *YOUR_GITHUB_USER* ]]; then
    echo "Set REPO at the top of curlup.sh (or export CURL_INSTALLERS_REPO=user/repo) to point at your GitHub repo." >&2; exit 1
  fi
  tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
  curl -fsSL "$FILE" -o "$tmp" || { echo "Could not download $FILE" >&2; exit 1; }
  FILE=$tmp
fi
[[ -r $FILE ]] || { echo "Cannot read $FILE" >&2; exit 1; }

# --- parse: one tool per name, each with an optional user and system command ---
names=() cats=() ucmd=() scmd=()
declare -A idx_of=()
while read -r name cat mode cmd; do
  [[ -z $name || $name == \#* ]] && continue
  if [[ $mode != user && $mode != system ]] || [[ -z $cmd ]]; then
    echo "Skipping malformed line for '$name' (mode must be user or system)" >&2; continue
  fi
  if [[ -z ${idx_of[$name]+x} ]]; then
    idx_of[$name]=${#names[@]}
    names+=("$name"); cats+=("$cat"); ucmd+=(""); scmd+=("")
  fi
  i=${idx_of[$name]}
  if [[ $mode == user ]]; then ucmd[i]=$cmd; else scmd[i]=$cmd; fi
done < "$FILE"

has_mode() { if [[ $2 == user ]]; then [[ -n ${ucmd[$1]} ]]; else [[ -n ${scmd[$1]} ]]; fi; }
modes() {
  if [[ -n ${ucmd[$1]} && -n ${scmd[$1]} ]]; then printf 'user+system'
  elif [[ -n ${ucmd[$1]} ]]; then printf 'user'
  else printf 'system'; fi
}

# visible tools: category filter, and -m hides tools that lack the preferred mode
visible=()
for i in "${!names[@]}"; do
  [[ -n $CATEGORY && ${cats[$i]} != "$CATEGORY" ]] && continue
  [[ -n $PREF ]] && ! has_mode "$i" "$PREF" && continue
  visible+=("$i")
done
(( ${#visible[@]} )) || { echo "No tools match${CATEGORY:+ category '$CATEGORY'}${PREF:+ with a $PREF installer}." >&2; exit 1; }

mark() { command -v "$1" >/dev/null 2>&1 && printf '✓' || printf ' '; }
row()  { printf '%s %-16s %-6s %-11s\n' "$(mark "${names[$1]}")" "${names[$1]}" "${cats[$1]}" "$(modes "$1")"; }
# read from the terminal even when the script itself arrives on stdin (curl | bash)
ask() { if { : </dev/tty; } 2>/dev/null; then read -r "$1" </dev/tty; else read -r "$1"; fi; }

if (( LIST )); then
  for i in "${visible[@]}"; do row "$i"; done
  exit 0
fi

# --- choose tools: entries are "index" or "index:mode" ---
chosen=()
if [[ -n $NAMES ]]; then
  IFS=',' read -ra want <<< "$NAMES"
  for w in "${want[@]}"; do
    n=${w%%:*} m=""; [[ $w == *:* ]] && m=${w#*:}
    if [[ -z ${idx_of[$n]+x} ]]; then echo "Unknown tool: $n (skipped)" >&2; continue; fi
    i=${idx_of[$n]}
    if [[ -n $m ]] && ! has_mode "$i" "$m"; then echo "$n has no $m installer (it has: $(modes "$i")), skipped" >&2; continue; fi
    chosen+=("$i${m:+:$m}")
  done
elif command -v fzf >/dev/null 2>&1; then
  while read -r i _; do [[ -n $i ]] && chosen+=("$i"); done < <(
    for i in "${visible[@]}"; do
      printf '%s\t%s\tuser:   %s\\nsystem: %s\n' "$i" "$(row "$i")" "${ucmd[$i]:-(none)}" "${scmd[$i]:-(none)}"
    done |
      fzf --multi --delimiter='\t' --with-nth=2 --height=80% --reverse \
          --header='TAB = select several, ENTER = install, ✓ = already installed' \
          --preview='printf "%b\n" {3}' --preview-window=down,4,wrap \
      | cut -f1
  )
else
  for k in "${!visible[@]}"; do printf '%3d) ' "$((k + 1))"; row "${visible[$k]}"; done
  printf '\nNumbers to install (space-separated, empty to quit): '
  ask line
  for n in $line; do
    if [[ $n =~ ^[0-9]+$ ]] && (( n >= 1 && n <= ${#visible[@]} )); then chosen+=("${visible[$((n - 1))]}")
    else echo "Ignoring '$n'" >&2; fi
  done
fi
(( ${#chosen[@]} )) || { echo "Nothing selected."; exit 0; }

# --- decide the mode for one tool ---
pick_mode() {  # $1=index, $2=forced mode or ""
  local i=$1 m=$2 ans
  if [[ -n $m ]]; then echo "$m"; return; fi
  if [[ -n $PREF ]] && has_mode "$i" "$PREF"; then echo "$PREF"; return; fi
  if [[ -n ${ucmd[$i]} && -z ${scmd[$i]} ]]; then echo user; return; fi
  if [[ -z ${ucmd[$i]} && -n ${scmd[$i]} ]]; then echo system; return; fi
  if (( YES || DRY )); then echo user; return; fi
  printf '    %s can install to your [u]ser home (no sudo) or [s]ystem-wide (sudo). Choice [u/s, default u]: ' "${names[$i]}" >&2
  ask ans
  [[ $ans == [sS]* ]] && echo system || echo user
}

# --- run ---
ok=() failed=() skipped=()
for entry in "${chosen[@]}"; do
  i=${entry%%:*} forced=""; [[ $entry == *:* ]] && forced=${entry#*:}
  name=${names[$i]}
  printf '\n\033[1m==> %s\033[0m  (%s)\n' "$name" "$(modes "$i")"
  mode=$(pick_mode "$i" "$forced")
  if [[ $mode == user ]]; then cmd=${ucmd[$i]}; else cmd=${scmd[$i]}; fi
  printf '    [%s] %s\n' "$mode" "$cmd"
  [[ $mode == system ]] && printf '    \033[33m! system-wide install: needs root and may ask for your password\033[0m\n'
  if (( DRY )); then continue; fi
  if (( ! YES )); then
    printf '    Run it? [y/N/v=view script] '
    ask a
    if [[ $a == v ]]; then
      url=$(grep -oE 'https?://[^ "|)]+' <<< "$cmd" | head -1)
      [[ -n $url ]] && curl -fsSL "$url" | "${PAGER:-less}"
      printf '    Run it? [y/N] '; ask a
    fi
    [[ $a == [yY]* ]] || { skipped+=("$name"); continue; }
  fi
  # give installers the terminal as stdin (for their own prompts), never the piped script
  if { : </dev/tty; } 2>/dev/null; then tty_in=/dev/tty; else tty_in=/dev/null; fi
  if (cd ~ && bash -c "$cmd" <"$tty_in"); then ok+=("$name($mode)"); else failed+=("$name"); fi
done

(( DRY )) && exit 0
echo
(( ${#ok[@]} ))      && echo "Installed: ${ok[*]}"
(( ${#skipped[@]} )) && echo "Skipped:   ${skipped[*]}"
(( ${#failed[@]} ))  && { echo "Failed:    ${failed[*]}"; exit 1; }
(( ${#ok[@]} )) && echo "Open a new shell (or source your rc file) so PATH changes take effect."
exit 0
}

main "$@"
