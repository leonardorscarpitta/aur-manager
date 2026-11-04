#!/bin/bash
set -euo pipefail

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
CYAN=$'\033[0;36m'
NC=$'\033[0m'
DIVISOR='=--=--=--=--=--=--=--=--=--=--=--=--=--='

AUR_URL="https://aur.archlinux.org"
RPC="$AUR_URL/rpc/v5"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/aur"

declare -A VISITED=()
declare -A TARGETS=()
ORDER=()

die()  { echo -e "${RED}error:${NC} $*" >&2; exit 1; }
info() { echo -e "${CYAN}::${NC} $*"; }
warn() { echo -e "${YELLOW}::${NC} $*"; }
ok()   { echo -e "${GREEN}::${NC} $*"; }

banner() {
    echo -e "$DIVISOR\n"
    echo -e "${CYAN} AUR Manager ${NC}\n"
    echo -e "$DIVISOR\n"
}

usage() {
    cat <<EOF
Usage: $(basename "$0") <command> [args]

Commands:
  -s, search <term>      Search the AUR
  -i, info <pkg>         Show package details
  -S, install <pkg>...   Build and install packages (with AUR dependencies)
  -u, update             Upgrade installed AUR packages
  -l, list               List installed foreign packages
  -c, clean              Remove the build cache ($CACHE)
  -h, help               Show this help
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
    read -rp "$1 [y/N] " answer
    [[ $answer == [yY] ]]
}

rpc() {
    local resp
    resp=$(curl -fsSL --proto '=https' --max-time 20 "$RPC/$1") || die "failed to reach $AUR_URL"
    [[ $(jq -r '.type' <<<"$resp") != error ]] || die "AUR: $(jq -r '.error' <<<"$resp")"
    printf '%s' "$resp"
}

cmd_search() {
    [[ -n ${1:-} ]] || die "usage: search <term>"
    local resp
    info "Fetching from aur.archlinux.org"
    resp=$(rpc "search/$(urlencode "$1")")
    if [[ $(jq '.resultcount' <<<"$resp") -eq 0 ]]; then
        warn "no results for '$1'"
        return
    fi
    jq -r --arg g "$GREEN" --arg n "$NC" '
        .results | sort_by(-.Popularity)[] |
        "\($g)\(.Name)\($n) \(.Version) (+\(.NumVotes))\(if .OutOfDate then " [out of date]" else "" end)\n    \(.Description // "")"
    ' <<<"$resp"
}

cmd_info() {
    valid_name "${1:-}" || die "invalid package name: ${1:-}"
    local resp
    resp=$(rpc "info?arg[]=$(urlencode "$1")")
    [[ $(jq '.resultcount' <<<"$resp") -gt 0 ]] || die "$1 not found in AUR"
    jq -r '.results[0] | [
        "Name          : \(.Name)",
        "Version       : \(.Version)",
        "Description   : \(.Description // "-")",
        "URL           : \(.URL // "-")",
        "Maintainer    : \(.Maintainer // "orphan")",
        "Votes         : \(.NumVotes)",
        "Out of date   : \(if .OutOfDate then (.OutOfDate | todate) else "no" end)",
        "Depends       : \((.Depends // []) | join(" "))",
        "Make depends  : \((.MakeDepends // []) | join(" "))",
        "Last modified : \(.LastModified | todate)"
    ] | .[]' <<<"$resp"
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
            git -C "$dir" diff "$old" HEAD | ${PAGER:-less}
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

install_pkgs() {
    local pkg
    for pkg in "$@"; do
        valid_name "$pkg" || die "invalid package name: $pkg"
        TARGETS[$pkg]=1
    done
    info "Resolving dependencies..."
    for pkg in "$@"; do
        resolve "$pkg"
    done

    info "Packages to build: ${ORDER[*]}"
    confirm "Proceed?" || exit 0

    mkdir -p "$CACHE"
    for pkg in "${ORDER[@]}"; do
        info "Review $pkg"
        fetch "$pkg"
    done
    confirm "Build and install ${ORDER[*]}?" || exit 0

    for pkg in "${ORDER[@]}"; do
        if [[ -n ${TARGETS[$pkg]:-} ]]; then
            build "$pkg"
        else
            build "$pkg" --asdeps
        fi
    done
    ok "Done"
}

cmd_install() {
    [[ $# -gt 0 ]] || die "usage: install <pkg>..."
    install_pkgs "$@"
}

cmd_update() {
    local -a names=() vers=() query=() outdated=()
    local -A remote=()
    local name ver resp latest i

    while read -r name ver; do
        names+=("$name")
        vers+=("$ver")
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

    for i in "${!names[@]}"; do
        name=${names[$i]}
        latest=${remote[$name]:-}
        if [[ -z $latest ]]; then
            warn "$name is not in the AUR, skipping"
            continue
        fi
        if (( $(vercmp "${vers[$i]}" "$latest") < 0 )); then
            echo "   $name ${vers[$i]} -> ${GREEN}$latest${NC}"
            outdated+=("$name")
        fi
    done

    if [[ ${#outdated[@]} -eq 0 ]]; then
        ok "All AUR packages are up to date"
        return
    fi
    install_pkgs "${outdated[@]}"
}

cmd_clean() {
    [[ -d $CACHE ]] || { info "Cache is already empty"; return; }
    confirm "Remove $CACHE?" || exit 0
    rm -rf -- "${CACHE:?}"
    ok "Cache removed"
}

main() {
    local cmd=${1:-help}
    shift || true

    case $cmd in
        -h|--help|help) usage; return ;;
    esac

    (( EUID != 0 )) || die "do not run as root; makepkg will call sudo when needed"
    check_deps
    banner

    case $cmd in
        -s|search)  cmd_search "$@" ;;
        -i|info)    cmd_info "$@" ;;
        -S|install) cmd_install "$@" ;;
        -u|update)  cmd_update ;;
        -l|list)    pacman -Qm ;;
        -c|clean)   cmd_clean ;;
        *)          usage; exit 1 ;;
    esac
}

main "$@"
