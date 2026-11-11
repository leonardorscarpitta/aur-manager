#!/bin/bash
set -euo pipefail

if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
  BOLD=$'\033[1m'
  DIM=$'\033[2m'
  RED=$'\033[1;31m'
  GREEN=$'\033[1;32m'
  YELLOW=$'\033[1;33m'
  BLUE=$'\033[1;34m'
  MAGENTA=$'\033[1;35m'
  CYAN=$'\033[1;36m'
  NC=$'\033[0m'
else
  BOLD='' DIM='' RED='' GREEN='' YELLOW='' BLUE='' MAGENTA='' CYAN='' NC=''
fi

AUR_URL="https://aur.archlinux.org"
RPC="$AUR_URL/rpc/v5"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/aur"
CACHE_SHOWN="${CACHE/#"$HOME"/\~}"

SCOPE=all # all | aur | repo, set by -a/--aur and -r/--repo

declare -A VISITED=()
declare -A TARGETS=()
declare -A OLD_HEAD=()
SELECTED=()
ORDER=()
SPIN_OUT=''

die() {
  echo "${RED}==> ERROR:${NC} ${BOLD}$*${NC}" >&2
  exit 1
}
info() { echo "${BLUE}==>${NC} ${BOLD}$*${NC}"; }
warn() { echo "${YELLOW}==> WARNING:${NC} ${BOLD}$*${NC}"; }
ok() { echo "${GREEN}==> ✔${NC} ${BOLD}$*${NC}"; }

banner() {
  echo
  echo "  ${CYAN}╭─────────────────────────────────────────╮${NC}"
  echo "  ${CYAN}│${NC}  ${CYAN}${NC}  ${BOLD}AUR Manager${NC}  ${DIM}·${NC}  ${DIM}aur.archlinux.org${NC}   ${CYAN}│${NC}"
  echo "  ${CYAN}╰─────────────────────────────────────────╯${NC}"
  echo
}

usage() {
  local name
  name=$(basename "$0")
  banner
  cat <<EOF
  ${BOLD}Usage:${NC} $name ${CYAN}<flag>${NC} ${DIM}[args] [-a | -r]${NC}
         $name ${CYAN}<term>${NC}                  ${DIM}search and pick packages to install${NC}

  ${BOLD}Flags:${NC}
    ${CYAN}-s${NC},     ${CYAN}--search${NC} ${DIM}<term>${NC}     Search the official repos and the AUR
    ${CYAN}-i${NC},     ${CYAN}--info${NC} ${DIM}<pkg>${NC}        Show package details
    ${CYAN}-S${NC},     ${CYAN}--install${NC} ${DIM}<pkg>...${NC}  Install packages ${DIM}(extra/<pkg> or aur/<pkg> picks the source)${NC}
    ${CYAN}-R${NC}${DIM}[ns]${NC}, ${CYAN}--remove${NC} ${DIM}<pkg>...${NC}   Uninstall packages ${DIM}(s: unneeded deps, n: config backups)${NC}
    ${CYAN}-u${NC},     ${CYAN}--update${NC}            Upgrade the system and AUR packages
    ${CYAN}-l${NC},     ${CYAN}--list${NC}              List installed AUR packages
    ${CYAN}-c${NC},     ${CYAN}--clean${NC}             Remove the build cache ${DIM}($CACHE_SHOWN)${NC}
    ${CYAN}-b${NC},     ${CYAN}--browse${NC} ${DIM}<pkg>${NC}      Browse a package's AUR repo ${DIM}(folders list, files open)${NC}
    ${CYAN}-h${NC},     ${CYAN}--help${NC}              Show this help

  ${BOLD}Modifiers:${NC}
    ${CYAN}-a${NC},     ${CYAN}--aur${NC}               Only use the AUR
    ${CYAN}-r${NC},     ${CYAN}--repo${NC}              Only use the official repos

EOF
}

check_deps() {
  local c
  for c in curl jq git makepkg pacman vercmp sudo; do
    command -v "$c" >/dev/null || die "missing dependency: $c"
  done
}

valid_name() { [[ ${1:-} =~ ^[a-z0-9@_+][a-z0-9@._+-]*$ ]]; }

# A package name, optionally prefixed with its source: extra/firefox, aur/yay.
valid_target() { [[ ${1:-} =~ ^([a-z0-9._-]+/)?[a-z0-9@_+][a-z0-9@._+-]*$ ]]; }

in_repos() { pacman -Si -- "$1" &>/dev/null; }

# Prints official repo matches for $1 as "repo<TAB>name<TAB>version<TAB>installed(0|1)<TAB>description".
repo_search() {
  local line rn ver='' rest repo='' name='' installed=0 list
  local -a repos=()
  mapfile -t repos < <(pacman-conf --repo-list 2>/dev/null || true)
  list=$(
    IFS=,
    echo "${repos[*]}"
  )
  list=${list//,/, }

  spin "searching ${list:-official repos}..." pacman -Ss -- "$1" || true
  [[ -n $SPIN_OUT ]] || return 0
  while IFS= read -r line; do
    if [[ $line == "    "* ]]; then
      printf '%s\t%s\t%s\t%s\t%s\n' "$repo" "$name" "$ver" "$installed" "${line#    }"
    else
      read -r rn ver rest <<<"$line"
      repo=${rn%%/*}
      name=${rn#*/}
      installed=0
      [[ $rest != *"[installed"* ]] || installed=1
    fi
  done <<<"$SPIN_OUT"
}

urlencode() { jq -rn --arg v "$1" '$v|@uri'; }

# confirm <question> [y|n]: the second argument is the answer used when the user just presses Enter.
confirm() {
  local answer default=${2:-n}
  if [[ $default == y ]]; then
    read -rp "${BLUE}::${NC} ${BOLD}$1${NC} [Y/n] " answer || return 1
    [[ -z $answer || $answer == [yY] ]]
  else
    read -rp "${BLUE}::${NC} ${BOLD}$1${NC} [y/N] " answer || return 1
    [[ $answer == [yY] ]]
  fi
}

# Prints "(n)" padded to the width of the largest index.
num_label() { printf '%s%*s%s' "$CYAN" $((${#2} + 2)) "($1)" "$NC"; }

# select_items <count> <question> [all|none|ranges]: reads a selection like "1-2,4" and fills SELECTED
# with 0-based indices in ascending order. Modes:
#   all    - Enter selects everything, "n" selects nothing
#   none   - Enter selects nothing, "a" selects everything
#   ranges - only numbers, ranges and commas; Enter selects nothing
select_items() {
  local count=$1 mode=${3:-all} answer part a b i valid hint
  local -a parts
  local -A picked
  case $mode in
  all) hint="[Enter = all, e.g. 1-2,4, n = none]" ;;
  none) hint="[Enter = none, e.g. 1-2,4, a = all]" ;;
  ranges) hint="[e.g. 1-2,4, Enter = cancel]" ;;
  esac
  while true; do
    SELECTED=()
    picked=()
    valid=1
    read -rp "${BLUE}::${NC} ${BOLD}$2${NC} ${DIM}$hint${NC} " answer || exit 1
    answer=${answer//[[:space:]]/,}

    if [[ -z ${answer//,/} ]]; then
      [[ $mode == all ]] || return 0
      answer=a
    fi
    if [[ $mode != ranges ]]; then
      case $answer in
      a | A | all)
        for ((i = 0; i < count; i++)); do SELECTED+=("$i"); done
        return 0
        ;;
      n | N | none)
        return 0
        ;;
      esac
    fi

    IFS=',' read -ra parts <<<"$answer"
    for part in "${parts[@]}"; do
      [[ -n $part ]] || continue
      if [[ $part =~ ^([0-9]+)-([0-9]+)$ ]]; then
        a=$((10#${BASH_REMATCH[1]})) b=$((10#${BASH_REMATCH[2]}))
      elif [[ $part =~ ^[0-9]+$ ]]; then
        a=$((10#$part)) b=$a
      else
        valid=0
        break
      fi
      if ((a < 1 || b > count || a > b)); then
        valid=0
        break
      fi
      for ((i = a; i <= b; i++)); do picked[$i]=1; done
    done

    if ((valid)); then
      for ((i = 1; i <= count; i++)); do
        [[ -z ${picked[$i]:-} ]] || SELECTED+=($((i - 1)))
      done
      return 0
    fi
    warn "invalid selection '$answer', use numbers from 1 to $count (e.g. 1-2,4)"
  done
}

# spin <message> <cmd>...: runs the command in the background with its stdout captured into SPIN_OUT
# (its stderr is discarded).
# On a terminal, a spinner with the message stays up for at least 0.5s (fetch time included) so it can be read.
spin() {
  local msg=$1 tmp pid start status=0 i=0 frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
  shift
  tmp=$(mktemp)
  "$@" >"$tmp" 2>/dev/null &
  pid=$!
  if [[ -t 2 ]]; then
    start=${EPOCHREALTIME/[.,]/}
    while kill -0 "$pid" 2>/dev/null || ((${EPOCHREALTIME/[.,]/} - start < 500000)); do
      printf '\r  %s %s' "${CYAN}${frames:i++%${#frames}:1}${NC}" "${DIM}$msg${NC}" >&2
      sleep 0.08
    done
    printf '\r\033[K' >&2
  fi
  wait "$pid" || status=$?
  SPIN_OUT=$(<"$tmp")
  rm -f -- "$tmp"
  return "$status"
}

rpc() {
  local resp status=0
  spin "fetching from aur.archlinux.org..." curl -fsSL --proto '=https' --max-time 20 "$RPC/$1" || status=$?
  resp=$SPIN_OUT
  ((status == 0)) || die "failed to reach $AUR_URL"
  [[ $(jq -r '.type' <<<"$resp") != error ]] || die "AUR: $(jq -r '.error' <<<"$resp")"
  printf '%s' "$resp"
}

# cmd_search <term> [pick]: official repo results are numbered first (1 = best official match), then AUR
# results by popularity. The list is printed bottom-up, so official packages sit right above the prompt
# and the least popular AUR result is at the top. With "pick", the user chooses which ones to install.
cmd_search() {
  [[ -n ${1:-} ]] || die "usage: -s, --search <term>"
  local term=$1 resp='{"resultcount":0,"results":[]}' installed i total repo_count aur_count numbered=false
  local repo name ver inst desc prefix tag pad=''
  local -a names=() chosen=() repo_lines=() entries=() aur_out=()
  [[ ${2:-} != pick ]] || numbered=true

  if [[ $SCOPE != aur ]]; then
    mapfile -t repo_lines < <(repo_search "$term")
  fi
  if [[ $SCOPE == aur ]]; then
    resp=$(rpc "search/$(urlencode "$term")")
  elif [[ $SCOPE == all ]]; then
    resp=$(rpc "search/$(urlencode "$term")") || {
      warn "AUR search failed, showing official repo results only"
      resp='{"resultcount":0,"results":[]}'
    }
  fi
  repo_count=${#repo_lines[@]}
  aur_count=$(jq '.resultcount' <<<"$resp")
  total=$((repo_count + aur_count))
  if ((total == 0)); then
    warn "no results for '$term'"
    return
  fi
  $numbered && printf -v pad '%*s' $((${#total} + 3)) ''

  for i in "${!repo_lines[@]}"; do
    IFS=$'\t' read -r repo name ver inst desc <<<"${repo_lines[$i]}"
    names+=("$repo/$name")
    prefix=""
    $numbered && prefix="$(num_label $((i + 1)) "$total") "
    tag=""
    ((inst == 0)) || tag=" ${CYAN}[installed]${NC}"
    entries+=("$prefix${BLUE}$repo/${NC}${BOLD}$name${NC} ${GREEN}$ver${NC}$tag"$'\n'"    $pad$desc")
  done

  # Each AUR result becomes exactly two lines (header, description), so they can be paired back up.
  installed=$({ pacman -Qmq || true; } | jq -Rn '[inputs]')
  mapfile -t aur_out < <(jq -r --argjson inst "$installed" --argjson numbered "$numbered" --argjson w $((${#total} + 2)) \
    --argjson off "$repo_count" \
    --arg b "$BOLD" --arg d "$DIM" --arg m "$MAGENTA" --arg g "$GREEN" \
    --arg r "$RED" --arg c "$CYAN" --arg y "$YELLOW" --arg n "$NC" '
        .results | sort_by(-.Popularity) | to_entries[] |
        (if $numbered then ("(\(.key + 1 + $off))" | (" " * ($w - length)) + .) else "" end) as $label |
        (if $numbered then " " * ($w + 1) else "" end) as $pad |
        .value |
        (if $numbered then "\($c)\($label)\($n) " else "" end)
        + "\($m)aur/\($n)\($b)\(.Name)\($n) \($g)\(.Version)\($n)"
        + " \($y)★ \(.NumVotes)\($n) \($d)(\(.Popularity * 100 | round / 100))\($n)"
        + (if .OutOfDate then " \($r)[out of date]\($n)" else "" end)
        + (if (.Name as $x | $inst | index($x)) then " \($c)[installed]\($n)" else "" end)
        + "\n    \($pad)\(.Description // "" | gsub("[\r\n]+"; " "))"
    ' <<<"$resp")
  for ((i = 0; i + 1 < ${#aur_out[@]}; i += 2)); do
    entries+=("${aur_out[i]}"$'\n'"${aur_out[i + 1]}")
  done
  while read -r name; do
    names+=("aur/$name")
  done < <(jq -r '.results | sort_by(-.Popularity)[].Name' <<<"$resp")

  for ((i = ${#entries[@]} - 1; i >= 0; i--)); do
    echo "${entries[i]}"
  done
  echo
  info "$total result(s) for '$term' ${DIM}($repo_count official, $aur_count AUR)${NC}"

  $numbered || return 0
  select_items "$total" "Packages to install?" ranges
  if [[ ${#SELECTED[@]} -eq 0 ]]; then
    info "Nothing selected"
    return
  fi
  for i in "${SELECTED[@]}"; do
    chosen+=("${names[$i]}")
  done
  install_targets "${chosen[@]}"
}

cmd_info() {
  local pkg=${1:-} resp
  valid_target "$pkg" || die "invalid package name: $pkg"
  if [[ $pkg != aur/* && $SCOPE != aur ]] && in_repos "$pkg"; then
    pacman -Si -- "$pkg"
    return
  fi
  [[ $pkg == aur/* || ($pkg != */* && $SCOPE != repo) ]] || die "$pkg not found in the official repos"
  pkg=${pkg#aur/}
  resp=$(rpc "info?arg[]=$(urlencode "$pkg")")
  [[ $(jq '.resultcount' <<<"$resp") -gt 0 ]] || die "$pkg not found in the official repos or the AUR"
  jq -r --arg b "$BOLD" --arg d "$DIM" --arg g "$GREEN" --arg r "$RED" \
    --arg c "$CYAN" --arg y "$YELLOW" --arg n "$NC" '
        def row(k; v): "  \($c)\(k)\($n)\(" " * (16 - (k | length)))\(v)";
        def deps(x): if (x // []) | length > 0 then (x | join("  ")) else "\($d)None\($n)" end;
        .results[0] |
        row("Name"; "\($b)\(.Name)\($n)"),
        row("Version"; "\($g)\(.Version)\($n)"),
        row("Description"; .Description // "-"),
        row("URL"; .URL // "-"),
        row("AUR page"; "https://aur.archlinux.org/packages/\(.Name)"),
        row("Maintainer"; .Maintainer // "\($r)orphan\($n)"),
        row("Votes"; "\($y)★ \(.NumVotes)\($n)  \($d)popularity \(.Popularity * 100 | round / 100)\($n)"),
        row("Out of date"; if .OutOfDate then "\($r)since \(.OutOfDate | todate)\($n)" else "\($g)no\($n)" end),
        row("Depends"; deps(.Depends)),
        row("Make depends"; deps(.MakeDepends)),
        row("Last modified"; .LastModified | todate)
    ' <<<"$resp"
  echo
}

# Prints the dependencies of $1 that are neither installed nor in the official repos.
aur_deps() {
  local resp dep name
  resp=$(rpc "info?arg[]=$(urlencode "$1")")
  [[ $(jq '.resultcount' <<<"$resp") -gt 0 ]] || die "$1 not found in AUR (if it's a virtual dependency, install a provider manually)"
  while read -r dep; do
    [[ -n $dep ]] || continue
    pacman -T "$dep" >/dev/null && continue
    name=${dep%%[<>=]*}
    pacman -Sp "$name" &>/dev/null && continue
    echo "$name"
  done < <(jq -r '.results[0] | (.Depends // []) + (.MakeDepends // []) + (.CheckDepends // []) | .[]' <<<"$resp")
}

resolve() {
  local pkg=$1 deps dep
  [[ -z ${VISITED[$pkg]:-} ]] || return 0
  VISITED[$pkg]=1
  valid_name "$pkg" || die "invalid package name: $pkg"
  deps=$(aur_deps "$pkg")
  for dep in $deps; do
    resolve "$dep"
  done
  ORDER+=("$pkg")
}

# Clones or updates the package repo, remembering the previous HEAD so review() can show a diff.
sync_repo() {
  local pkg=$1 dir="$CACHE/$1"
  if [[ -d $dir/.git ]]; then
    OLD_HEAD[$pkg]=$(git -C "$dir" rev-parse HEAD)
    git -C "$dir" pull -q --ff-only || die "failed to update $pkg repo"
  else
    git clone -q "$AUR_URL/$pkg.git" "$dir" || die "failed to clone $pkg"
  fi
  [[ -f $dir/PKGBUILD ]] || {
    rm -rf -- "$dir"
    die "$pkg has no PKGBUILD"
  }
}

# Shows the diff since the last build if the repo changed, otherwise the full PKGBUILD.
review() {
  local pkg=$1 dir="$CACHE/$1" old=${OLD_HEAD[$1]:-}
  if [[ -n $old && $old != "$(git -C "$dir" rev-parse HEAD)" ]]; then
    git -C "$dir" -c color.ui=always diff "$old" HEAD | ${PAGER:-less -R}
  else
    ${PAGER:-less} "$dir/PKGBUILD"
  fi
}

build() {
  local pkg=$1
  shift
  (cd "$CACHE/$pkg" && makepkg -si --needed "$@") || die "build failed for $pkg"
}

print_plan() {
  local pkg i total=${#ORDER[@]} tag
  echo
  echo "  ${BOLD}Packages ($total)${NC}"
  for i in "${!ORDER[@]}"; do
    pkg=${ORDER[$i]}
    tag=""
    [[ -n ${TARGETS[$pkg]:-} ]] || tag=" ${DIM}(dependency)${NC}"
    [[ -z ${OLD_HEAD[$pkg]:-} || ${OLD_HEAD[$pkg]} == "$(git -C "$CACHE/$pkg" rev-parse HEAD)" ]] ||
      tag+=" ${YELLOW}(changed)${NC}"
    echo "    $(num_label $((i + 1)) "$total") ${MAGENTA}aur/${NC}${BOLD}$pkg${NC}$tag"
  done
  echo
}

install_pkgs() {
  local pkg i total
  for pkg in "$@"; do
    valid_name "$pkg" || die "invalid package name: $pkg"
    TARGETS[$pkg]=1
  done
  info "Resolving dependencies..."
  for pkg in "$@"; do
    resolve "$pkg"
  done
  total=${#ORDER[@]}

  mkdir -p "$CACHE"
  info "Fetching build files..."
  for pkg in "${ORDER[@]}"; do
    sync_repo "$pkg"
  done

  print_plan
  select_items "$total" "PKGBUILDs to review?" none
  if [[ ${#SELECTED[@]} -eq 0 ]]; then
    warn "skipping PKGBUILD review, make sure you trust these packages"
  fi
  for i in "${SELECTED[@]}"; do
    info "Reviewing ${CYAN}${ORDER[$i]}${NC}"
    review "${ORDER[$i]}"
  done
  confirm "Build and install $total package(s)?" y || exit 0

  i=0
  for pkg in "${ORDER[@]}"; do
    echo
    info "Building ${CYAN}$pkg${NC} ${DIM}($((++i))/$total)${NC}"
    if [[ -n ${TARGETS[$pkg]:-} ]]; then
      build "$pkg"
    else
      build "$pkg" --asdeps
    fi
  done
  echo
  ok "Installed ${ORDER[*]}"
}

# install_targets <pkg>...: packages in the official repos go to pacman, the rest are built from the AUR.
# A "<repo>/" or "aur/" prefix forces the source.
install_targets() {
  local pkg
  local -a repo_pkgs=() aur_pkgs=()
  for pkg in "$@"; do
    valid_target "$pkg" || die "invalid package name: $pkg"
    case $pkg in
    aur/*)
      [[ $SCOPE != repo ]] || die "$pkg is an AUR package, but -r/--repo was given"
      aur_pkgs+=("${pkg#aur/}")
      ;;
    */*)
      [[ $SCOPE != aur ]] || die "$pkg is an official repo package, but -a/--aur was given"
      repo_pkgs+=("$pkg")
      ;;
    *)
      if [[ $SCOPE != aur ]] && in_repos "$pkg"; then
        repo_pkgs+=("$pkg")
      elif [[ $SCOPE != repo ]]; then
        aur_pkgs+=("$pkg")
      else
        die "$pkg not found in the official repos"
      fi
      ;;
    esac
  done

  if [[ ${#repo_pkgs[@]} -gt 0 ]]; then
    info "Installing from the official repos: ${repo_pkgs[*]}"
    sudo pacman -S --needed -- "${repo_pkgs[@]}" || exit 1
    echo
  fi
  [[ ${#aur_pkgs[@]} -eq 0 ]] || install_pkgs "${aur_pkgs[@]}"
}

cmd_install() {
  [[ $# -gt 0 ]] || die "usage: -S, --install <pkg>..."
  install_targets "$@"
}

cmd_update() {
  local -a names=() vers=() query=() outdated=() current=() available=() chosen=()
  local -A remote=()
  local name ver resp latest i width=0

  if [[ $SCOPE != aur ]]; then
    info "Upgrading official repo packages..."
    sudo pacman -Syu || warn "official repo upgrade did not complete"
    echo
  fi
  [[ $SCOPE != repo ]] || return 0

  while read -r name ver; do
    names+=("$name")
    vers+=("$ver")
    ((${#name} > width)) && width=${#name}
  done < <(pacman -Qm)
  if [[ ${#names[@]} -eq 0 ]]; then
    info "No foreign packages installed"
    return
  fi

  info "Checking ${#names[@]} package(s) against the AUR..."
  for name in "${names[@]}"; do
    query+=("arg[]=$(urlencode "$name")")
  done
  resp=$(rpc "info?$(
    IFS='&'
    echo "${query[*]}"
  )")
  while IFS=$'\t' read -r name ver; do
    remote[$name]=$ver
  done < <(jq -r '.results[] | "\(.Name)\t\(.Version)"' <<<"$resp")

  echo
  for i in "${!names[@]}"; do
    name=${names[$i]}
    latest=${remote[$name]:-}
    if [[ -z $latest ]]; then
      printf '    %s%-*s%s  %s\n' "$DIM" "$width" "$name" "$NC" "${YELLOW}not in the AUR${NC}"
    elif (($(vercmp "${vers[$i]}" "$latest") < 0)); then
      outdated+=("$name")
      current+=("${vers[$i]}")
      available+=("$latest")
    else
      printf '    %-*s  %s\n' "$width" "$name" "${DIM}${vers[$i]} (up to date)${NC}"
    fi
  done
  echo

  if [[ ${#outdated[@]} -eq 0 ]]; then
    ok "All AUR packages are up to date"
    return
  fi

  info "${#outdated[@]} package(s) available to update:"
  for i in "${!outdated[@]}"; do
    printf '    %s %s%-*s%s  %s  →  %s\n' "$(num_label $((i + 1)) "${#outdated[@]}")" \
      "$BOLD" "$width" "${outdated[$i]}" "$NC" "${RED}${current[$i]}${NC}" "${GREEN}${available[$i]}${NC}"
  done
  echo

  select_items "${#outdated[@]}" "Packages to update?"
  if [[ ${#SELECTED[@]} -eq 0 ]]; then
    info "Nothing selected"
    return
  fi
  for i in "${SELECTED[@]}"; do
    chosen+=("${outdated[$i]}")
  done
  install_pkgs "${chosen[@]}"
}

# A remove flag is "-" plus R, n and s in any order, with exactly one R: -R, -Rn, -Rs, -Rns, -sRn...
valid_remove_flag() { [[ $1 =~ ^-[Rns]+$ && ${1//[^R]/} == R ]]; }

# cmd_remove <flag> <pkg>...: uninstalls packages with "pacman <flag>", the flag passed exactly as typed.
cmd_remove() {
  local flag=$1 pkg name need extra=""
  local -a targets=()
  shift
  [[ $# -gt 0 ]] || die "usage: -R[ns], --remove <pkg>..."

  for pkg in "$@"; do
    valid_target "$pkg" || die "invalid package name: $pkg"
    case $pkg in
    aur/*) need=aur ;;
    */*) need=repo ;;
    *) need=$SCOPE ;;
    esac
    name=${pkg#*/}
    # pacman -Q follows "provides" (e.g. sh -> bash), so require an exact name match.
    [[ $(pacman -Qq -- "$name" 2>/dev/null) == "$name" ]] || die "$name is not installed"
    if [[ $need == aur ]] && ! pacman -Qmq -- "$name" &>/dev/null; then
      die "$name is not an AUR package"
    fi
    if [[ $need == repo ]] && ! pacman -Qnq -- "$name" &>/dev/null; then
      die "$name is not an official repo package"
    fi
    targets+=("$name")
  done

  [[ $flag != *s* ]] || extra+=", unneeded dependencies"
  [[ $flag != *n* ]] || extra+=", config backups"
  info "Removing ${targets[*]}${extra:+ ${DIM}(+${extra#, })${NC}}"
  sudo pacman "$flag" -- "${targets[@]}" || exit 1
  echo
  ok "Removed ${targets[*]}"
}

# cmd_browse <pkg> [path]: browses the package's AUR git repo. Picking a folder lists it, picking a file
# opens it in the pager. Paths are resolved and must stay inside the repo and outside .git.
cmd_browse() {
  local pkg=${1:-} rel=${2:-} root target answer i
  local -a dirs files entries
  pkg=${pkg#aur/}
  valid_name "$pkg" || die "usage: -b, --browse <pkg> [path]"

  mkdir -p "$CACHE"
  info "Fetching ${CYAN}$pkg${NC}..."
  sync_repo "$pkg"
  root=$(realpath -- "$CACHE/$pkg")

  while true; do
    rel=${rel#/}
    rel=${rel%/}
    target=$(realpath -m -- "$root${rel:+/$rel}")
    if [[ ($target != "$root" && $target != "$root"/*) || $target == "$root/.git" || $target == "$root"/.git/* ]]; then
      die "path is outside the package repo: ${rel:-/}"
    fi
    [[ -e $target ]] || die "no such file or folder: $rel"
    rel=${target#"$root"}
    rel=${rel#/}

    if [[ -f $target ]]; then
      ${PAGER:-less} "$target"
      rel=$(dirname -- "$rel")
      [[ $rel != . ]] || rel=""
      continue
    fi

    mapfile -t dirs < <(find "$target" -mindepth 1 -maxdepth 1 -type d ! -name .git -printf '%f\n' | sort)
    mapfile -t files < <(find "$target" -mindepth 1 -maxdepth 1 ! -type d -printf '%f\n' | sort)
    entries=("${dirs[@]/%//}" "${files[@]}")

    echo
    echo "  ${MAGENTA}aur/${NC}${BOLD}$pkg${NC}${DIM}:/$rel${NC}"
    [[ -z $rel ]] || echo "    $(num_label 0 "${#entries[@]}") ${DIM}../${NC}"
    for i in "${!entries[@]}"; do
      if [[ ${entries[i]} == */ ]]; then
        echo "    $(num_label $((i + 1)) "${#entries[@]}") ${BLUE}${entries[i]}${NC}"
      else
        echo "    $(num_label $((i + 1)) "${#entries[@]}") ${entries[i]}"
      fi
    done
    echo

    read -rp "${BLUE}::${NC} ${BOLD}Open?${NC} ${DIM}[number${rel:+, 0 / .. / b = back}, Enter = quit]${NC} " answer || return 0
    answer=${answer//[[:space:]]/}
    [[ -n $answer ]] || return 0
    if [[ ($answer == 0 || $answer == .. || $answer == [bB]) && -n $rel ]]; then
      rel=$(dirname -- "$rel")
      [[ $rel != . ]] || rel=""
    elif [[ $answer =~ ^[0-9]+$ ]] && ((10#$answer >= 1 && 10#$answer <= ${#entries[@]})); then
      i=$((10#$answer - 1))
      rel="${rel:+$rel/}${entries[i]%/}"
    else
      warn "invalid choice '$answer'"
    fi
  done
}

cmd_list() {
  local name ver count=0
  while read -r name ver; do
    echo "    ${MAGENTA}aur/${NC}${BOLD}$name${NC} ${GREEN}$ver${NC}"
    count=$((count + 1))
  done < <(pacman -Qm)
  echo
  info "$count foreign package(s) installed"
}

cmd_clean() {
  [[ -d $CACHE ]] || {
    info "Cache is already empty"
    return
  }
  info "Cache: $CACHE_SHOWN ${DIM}($(du -sh -- "$CACHE" | cut -f1))${NC}"
  confirm "Remove it?" || exit 0
  rm -rf -- "${CACHE:?}"
  ok "Cache removed"
}

main() {
  local arg cmd
  local -a args=()
  for arg in "$@"; do
    case $arg in
    -a | --aur | -r | --repo)
      [[ $SCOPE == all ]] || die "use either -a/--aur or -r/--repo, not both"
      [[ $arg == -a || $arg == --aur ]] && SCOPE=aur || SCOPE=repo
      ;;
    *)
      args+=("$arg")
      ;;
    esac
  done
  set -- "${args[@]}"

  cmd=${1:--h}
  shift || true

  case $cmd in
  -h | --help)
    usage
    return
    ;;
  esac

  ((EUID != 0)) || die "do not run as root; sudo is called when needed"
  check_deps
  banner

  case $cmd in
  -s | --search) cmd_search "$@" ;;
  -i | --info) cmd_info "$@" ;;
  -S | --install) cmd_install "$@" ;;
  --remove) cmd_remove -R "$@" ;;
  -u | --update) cmd_update ;;
  -l | --list) cmd_list ;;
  -c | --clean) cmd_clean ;;
  -b | --browse) cmd_browse "$@" ;;
  -*)
    if valid_remove_flag "$cmd"; then
      cmd_remove "$cmd" "$@"
    else
      usage
      exit 1
    fi
    ;;
  *) cmd_search "$cmd" pick ;;
  esac
}

main "$@"
