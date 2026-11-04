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

declare -A VISITED=()
declare -A TARGETS=()
ORDER=()

die()  { echo "${RED}==> ERROR:${NC} ${BOLD}$*${NC}" >&2; exit 1; }
info() { echo "${BLUE}==>${NC} ${BOLD}$*${NC}"; }
warn() { echo "${YELLOW}==> WARNING:${NC} ${BOLD}$*${NC}"; }
ok()   { echo "${GREEN}==> ✔${NC} ${BOLD}$*${NC}"; }

banner() {
    echo
    echo "  ${CYAN}╭───────────────────────────────────────╮${NC}"
    echo "  ${CYAN}│${NC}  ${CYAN}▲${NC} ${BOLD}AUR Manager${NC}  ${DIM}·${NC}  ${DIM}aur.archlinux.org${NC}  ${CYAN}│${NC}"
    echo "  ${CYAN}╰───────────────────────────────────────╯${NC}"
    echo
}

usage() {
    local name
    name=$(basename "$0")
    banner
    cat <<EOF
  ${BOLD}Usage:${NC} $name ${CYAN}<flag>${NC} ${DIM}[args]${NC}
         $name ${CYAN}<term>${NC}         ${DIM}same as -s <term>${NC}

  ${BOLD}Flags:${NC}
    ${CYAN}-s${NC} ${DIM}<term>${NC}         Search the AUR
    ${CYAN}-i${NC} ${DIM}<pkg>${NC}          Show package details
    ${CYAN}-S${NC} ${DIM}<pkg>...${NC}       Build and install packages (with AUR dependencies)
    ${CYAN}-u${NC}                Upgrade installed AUR packages
    ${CYAN}-l${NC}                List installed foreign packages
    ${CYAN}-c${NC}                Remove the build cache ${DIM}($CACHE_SHOWN)${NC}
    ${CYAN}-h${NC}, ${CYAN}--help${NC}        Show this help

EOF
}

check_deps() {
    local c
    for c in curl jq git makepkg pacman vercmp; do
        command -v "$c" >/dev/null || die "missing dependency: $c"
    done
}

valid_name() { [[ ${1:-} =~ ^[a-z0-9@_+][a-z0-9@._+-]*$ ]]; }

urlencode() { jq -rn --arg v "$1" '$v|@uri'; }

confirm() {
    local answer
    read -rp "${BLUE}::${NC} ${BOLD}$1${NC} [y/N] " answer
    [[ $answer == [yY] ]]
}

# Runs curl in the background and draws a spinner on stderr while it waits.
rpc() {
    local tmp pid resp status=0 i=0 frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    tmp=$(mktemp)
    curl -fsSL --proto '=https' --max-time 20 -o "$tmp" "$RPC/$1" &
    pid=$!
    if [[ -t 2 ]]; then
        while kill -0 "$pid" 2>/dev/null; do
            printf '\r  %s %s' "${CYAN}${frames:i++%${#frames}:1}${NC}" "${DIM}querying aur.archlinux.org...${NC}" >&2
            sleep 0.08
        done
        printf '\r\033[K' >&2
    fi
    wait "$pid" || status=$?
    resp=$(<"$tmp")
    rm -f -- "$tmp"
    (( status == 0 )) || die "failed to reach $AUR_URL"
    [[ $(jq -r '.type' <<<"$resp") != error ]] || die "AUR: $(jq -r '.error' <<<"$resp")"
    printf '%s' "$resp"
}

cmd_search() {
    [[ -n ${1:-} ]] || die "usage: -s <term>"
    local resp installed count
    resp=$(rpc "search/$(urlencode "$1")")
    count=$(jq '.resultcount' <<<"$resp")
    if (( count == 0 )); then
        warn "no results for '$1'"
        return
    fi
    installed=$(pacman -Qmq | jq -Rn '[inputs]')
    jq -r --argjson inst "$installed" \
        --arg b "$BOLD" --arg d "$DIM" --arg m "$MAGENTA" --arg g "$GREEN" \
        --arg r "$RED" --arg c "$CYAN" --arg y "$YELLOW" --arg n "$NC" '
        .results | sort_by(-.Popularity)[] |
        "\($m)aur/\($n)\($b)\(.Name)\($n) \($g)\(.Version)\($n)"
        + " \($y)★ \(.NumVotes)\($n) \($d)(\(.Popularity * 100 | round / 100))\($n)"
        + (if .OutOfDate then " \($r)[out of date]\($n)" else "" end)
        + (if (.Name as $x | $inst | index($x)) then " \($c)[installed]\($n)" else "" end)
        + "\n    \(.Description // "")"
    ' <<<"$resp"
    echo
    info "$count result(s) for '$1'"
}

cmd_info() {
    valid_name "${1:-}" || die "invalid package name: ${1:-}"
    local resp
    resp=$(rpc "info?arg[]=$(urlencode "$1")")
    [[ $(jq '.resultcount' <<<"$resp") -gt 0 ]] || die "$1 not found in AUR"
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

# Clones or updates the package repo and shows the PKGBUILD (or the diff since last time) for review.
fetch() {
    local pkg=$1 dir="$CACHE/$1" old
    if [[ -d $dir/.git ]]; then
        old=$(git -C "$dir" rev-parse HEAD)
        git -C "$dir" pull -q --ff-only || die "failed to update $pkg repo"
        if [[ $old != "$(git -C "$dir" rev-parse HEAD)" ]]; then
            git -C "$dir" -c color.ui=always diff "$old" HEAD | ${PAGER:-less -R}
            return
        fi
    else
        git clone -q "$AUR_URL/$pkg.git" "$dir" || die "failed to clone $pkg"
    fi
    [[ -f $dir/PKGBUILD ]] || { rm -rf -- "$dir"; die "$pkg has no PKGBUILD"; }
    ${PAGER:-less} "$dir/PKGBUILD"
}

build() {
    local pkg=$1; shift
    (cd "$CACHE/$pkg" && makepkg -si --needed "$@") || die "build failed for $pkg"
}

print_plan() {
    local pkg
    echo
    echo "  ${BOLD}Packages (${#ORDER[@]})${NC}"
    for pkg in "${ORDER[@]}"; do
        if [[ -n ${TARGETS[$pkg]:-} ]]; then
            echo "    ${MAGENTA}aur/${NC}${BOLD}$pkg${NC}"
        else
            echo "    ${MAGENTA}aur/${NC}${BOLD}$pkg${NC} ${DIM}(dependency)${NC}"
        fi
    done
    echo
}

install_pkgs() {
    local pkg i=0 total
    for pkg in "$@"; do
        valid_name "$pkg" || die "invalid package name: $pkg"
        TARGETS[$pkg]=1
    done
    info "Resolving dependencies..."
    for pkg in "$@"; do
        resolve "$pkg"
    done
    total=${#ORDER[@]}

    print_plan
    confirm "Review PKGBUILDs and continue?" || exit 0

    mkdir -p "$CACHE"
    for pkg in "${ORDER[@]}"; do
        info "Reviewing ${CYAN}$pkg${NC} ${DIM}($((++i))/$total)${NC}"
        fetch "$pkg"
    done
    confirm "Build and install $total package(s)?" || exit 0

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

cmd_install() {
    [[ $# -gt 0 ]] || die "usage: -S <pkg>..."
    install_pkgs "$@"
}

cmd_update() {
    local -a names=() vers=() query=() outdated=()
    local -A remote=()
    local name ver resp latest i width=0

    while read -r name ver; do
        names+=("$name")
        vers+=("$ver")
        (( ${#name} > width )) && width=${#name}
    done < <(pacman -Qm)
    if [[ ${#names[@]} -eq 0 ]]; then
        info "No foreign packages installed"
        return
    fi

    info "Checking ${#names[@]} package(s) against the AUR..."
    for name in "${names[@]}"; do
        query+=("arg[]=$(urlencode "$name")")
    done
    resp=$(rpc "info?$(IFS='&'; echo "${query[*]}")")
    while IFS=$'\t' read -r name ver; do
        remote[$name]=$ver
    done < <(jq -r '.results[] | "\(.Name)\t\(.Version)"' <<<"$resp")

    echo
    for i in "${!names[@]}"; do
        name=${names[$i]}
        latest=${remote[$name]:-}
        if [[ -z $latest ]]; then
            printf '    %s%-*s%s  %s\n' "$DIM" "$width" "$name" "$NC" "${YELLOW}not in the AUR${NC}"
        elif (( $(vercmp "${vers[$i]}" "$latest") < 0 )); then
            printf '    %s%-*s%s  %s  →  %s\n' "$BOLD" "$width" "$name" "$NC" "${RED}${vers[$i]}${NC}" "${GREEN}$latest${NC}"
            outdated+=("$name")
        else
            printf '    %-*s  %s\n' "$width" "$name" "${DIM}${vers[$i]} (up to date)${NC}"
        fi
    done
    echo

    if [[ ${#outdated[@]} -eq 0 ]]; then
        ok "All AUR packages are up to date"
        return
    fi
    install_pkgs "${outdated[@]}"
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
    [[ -d $CACHE ]] || { info "Cache is already empty"; return; }
    info "Cache: $CACHE_SHOWN ${DIM}($(du -sh -- "$CACHE" | cut -f1))${NC}"
    confirm "Remove it?" || exit 0
    rm -rf -- "${CACHE:?}"
    ok "Cache removed"
}

main() {
    local cmd=${1:--h}
    shift || true

    case $cmd in
        -h|--help) usage; return ;;
    esac

    (( EUID != 0 )) || die "do not run as root; makepkg will call sudo when needed"
    check_deps
    banner

    case $cmd in
        -s) cmd_search "$@" ;;
        -i) cmd_info "$@" ;;
        -S) cmd_install "$@" ;;
        -u) cmd_update ;;
        -l) cmd_list ;;
        -c) cmd_clean ;;
        -*) usage; exit 1 ;;
        *)  cmd_search "$cmd" ;;
    esac
}

main "$@"
