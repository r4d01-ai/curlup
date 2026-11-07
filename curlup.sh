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
  CATEGORY              only show one category: ai lang shell editor cli infra k8s net cloud sec data browsers
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
names=() cats=() homes=() ucmd=() scmd=()
declare -A idx_of=()
while read -r name cat mode home cmd; do
  [[ -z $name || $name == \#* ]] && continue
  if [[ $mode != user && $mode != system ]] || [[ ! $home =~ ^https?:// ]] || [[ -z $cmd ]]; then
    echo "Skipping malformed line for '$name' (format: name category user|system homepage-URL command)" >&2; continue
  fi
  if [[ -z ${idx_of[$name]+x} ]]; then
    idx_of[$name]=${#names[@]}
    names+=("$name"); cats+=("$cat"); homes+=("$home"); ucmd+=(""); scmd+=("")
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
# default order: by category, then by name
mapfile -t visible < <(for i in "${visible[@]}"; do printf '%s\t%s\t%s\n' "${cats[$i]}" "${names[$i]}" "$i"; done | LC_ALL=C sort | cut -f3)

mark() { command -v "$1" >/dev/null 2>&1 && printf '✓' || printf ' '; }
row()  { printf '%s %-16s %-6s %-11s\n' "$(mark "${names[$1]}")" "${names[$1]}" "${cats[$1]}" "$(modes "$1")"; }
# read from the terminal even when the script itself arrives on stdin (curl | bash)
ask() { if { : </dev/tty; } 2>/dev/null; then read -r "$1" </dev/tty; else read -r "$1"; fi; }

if (( LIST )); then
  for i in "${visible[@]}"; do row "$i"; done
  exit 0
fi

# --- fzf picker: needs fzf >= FZF_MIN and an fzf that accepts the picker's options.
# If that's missing, offer to install it; no answer within 5s falls back to the numbered menu.
FZF_MIN=0.38.0
fzf_style() {  # fills style=(), the picker's look: Blade Runner amber/teal over synthwave magenta/violet
  style=(--border=rounded --border-label=' CURLUP // TOOL SELECT ' --border-label-pos=center
         --prompt='◢ ' --pointer='▶' --marker='◆' --info=inline-right)
  # NO_COLOR (https://no-color.org) drops the colours and keeps the layout
  if [[ -z ${NO_COLOR:-} ]]; then
    style+=(--color='bg:#0b0c1a,bg+:#2a1248,fg:#c9c3d9,fg+:#ffffff,hl:#ff2a6d,hl+:#ff6ac1,info:#7b2ff7,prompt:#ffb000,pointer:#05d9e8,marker:#ffd319,spinner:#05d9e8,header:#ff9f1c,border:#05d9e8,label:#ffb000')
  fi
}
fzf_usable() {  # fzf on PATH, new enough, and accepting the picker's options
  command -v fzf >/dev/null 2>&1 || return 1
  local v rc
  v=$(fzf --version 2>/dev/null | awk '{print $1}')
  [[ -n $v && $(printf '%s\n' "$FZF_MIN" "$v" | sort -V | head -1) == "$FZF_MIN" ]] || return 1
  fzf --filter=x "${style[@]}" </dev/null >/dev/null 2>&1; rc=$?
  (( rc != 2 ))  # fzf exits 2 on a bad option
}
install_fzf() {  # install or upgrade fzf with the system package manager
  local sudo=()
  if (( EUID != 0 )); then command -v sudo >/dev/null 2>&1 || return 1; sudo=(sudo); fi
  if command -v brew >/dev/null 2>&1; then brew install fzf
  elif command -v apt-get >/dev/null 2>&1; then "${sudo[@]}" apt-get update -qq && "${sudo[@]}" apt-get install -y -q fzf
  elif command -v dnf >/dev/null 2>&1; then "${sudo[@]}" dnf install -y fzf
  elif command -v pacman >/dev/null 2>&1; then "${sudo[@]}" pacman -S --noconfirm fzf
  elif command -v apk >/dev/null 2>&1; then "${sudo[@]}" apk add fzf
  else return 1
  fi
}
ensure_fzf() {  # 0 = use the fzf picker, 1 = use the numbered menu
  fzf_style
  fzf_usable && return 0
  (( YES )) && return 1
  { : </dev/tty; } 2>/dev/null || return 1
  if command -v fzf >/dev/null 2>&1; then
    echo "fzf is older than $FZF_MIN or missing options the picker needs ($(fzf --version 2>/dev/null))." >&2
  else
    echo "fzf is not installed." >&2
  fi
  printf 'Install or upgrade fzf for the picker? [y/N] (no answer in 5s: plain menu) ' >&2
  local a=""
  read -r -t 5 a </dev/tty || { echo >&2; return 1; }
  [[ $a == [yY]* ]] || return 1
  install_fzf </dev/tty || { echo "fzf install failed, using the plain menu." >&2; return 1; }
  fzf_usable
}

pick_fzf() {  # prints the chosen tool indices, one per line
  local dir tab=$'\t' i link pv
  dir=$(mktemp -d) || return 1
  trap 'rm -rf "$dir"' RETURN
  # one row per tool: index, shown text, preview, name (search key), category
  for i in "${visible[@]}"; do
    # the preview is %b-escaped by fzf, so \e is ESC and \\ a backslash; the link is OSC 8 (clickable in most terminals)
    link="\\e]8;;${homes[$i]}\\e\\\\${homes[$i]}\\e]8;;\\e\\\\"
    pv="homepage: $link\\nuser:   ${ucmd[$i]:-(none)}\\nsystem: ${scmd[$i]:-(none)}"
    printf '%s\t%s\t%s\t%s\t%s\n' "$i" "$(row "$i")" "$pv" "${names[$i]}" "${cats[$i]}"
  done > "$dir/rows.tsv"
  # typing re-runs this: no query shows category then name, a query shows only matching names, sorted by name
  cat > "$dir/filter.sh" <<'FILTER'
#!/bin/sh
dir=$1 q=$2 tab=$(printf '\t')
if [ -n "$q" ]; then
  Q=$q LC_ALL=C awk -F '\t' 'index(tolower($4), tolower(ENVIRON["Q"]))' "$dir/rows.tsv" | LC_ALL=C sort -t "$tab" -k4,4
else
  LC_ALL=C sort -t "$tab" -k5,5 -k4,4 "$dir/rows.tsv"
fi
FILTER
  LC_ALL=C sort -t "$tab" -k5,5 -k4,4 "$dir/rows.tsv" |
    fzf --multi --disabled --no-sort --delimiter="$tab" --with-nth=2 --height=80% --reverse "${style[@]}" \
        --bind "change:reload(sh $(printf %q "$dir/filter.sh") $(printf %q "$dir") {q})" \
        --header='TAB = select several · ENTER = install · type to search by name · ✓ = installed' \
        --preview='printf "%b\n" {3}' --preview-window=down,4,wrap \
    | cut -f1
}

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
elif ensure_fzf; then
  while read -r i; do [[ -n $i ]] && chosen+=("$i"); done < <(pick_fzf)
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
