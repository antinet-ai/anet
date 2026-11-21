#!/usr/bin/env bash
# Installs a signed anet preview release (specs/0079 PUB-7, PUB-12, PUB-17).
#
#   install.sh [--release <n>] [--no-provenance]
#   install.sh --archive <anet-<n>-<platform>.tar.gz> --bundle <its .sigstore.json> --trusted-root <file>
#
# Downloads the archive for this machine from the public release page, checks
# its SHA-256 and its Sigstore signature (made by Antinet's release workflow),
# checks that the engine carries the release key pinned below, then installs
# it: on Linux as the system service (or as an update of the installed one),
# on macOS for this account.
#
# --archive installs from files carried in, for a site with no network. Save
# Sigstore's trusted root on a connected machine with `cosign initialize`, then
# copy ~/.sigstore/root/tuf-repo-cdn.sigstore.dev/targets/trusted_root.json.
set -euo pipefail

# Written by the release workflow from the key compiled into the release.
pinned_release_key="ed25519:0179b8f16d37b7afeb39741540ea6f1996b54bf8ac0758767d823d6c29b9ba6d ml-dsa-65:c198361b7e3be5af3192cb06dfea2b3f1069cf36da224bc8bab74d2cc14b69ad"

public_repository="antinet-ai/anet"
source_repository="antinet-ai/antinet"

usage() {
    sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//' >&2
    exit 2
}
fail() {
    echo "install.sh: $*" >&2
    exit 1
}

release="" archive="" bundle="" trusted_root="" check_provenance=yes
while [ $# -gt 0 ]; do
    case "$1" in
        --release) release="${2:?--release needs a value}"; shift 2 ;;
        --archive) archive="${2:?--archive needs a value}"; shift 2 ;;
        --bundle) bundle="${2:?--bundle needs a value}"; shift 2 ;;
        --trusted-root) trusted_root="${2:?--trusted-root needs a value}"; shift 2 ;;
        --no-provenance) check_provenance=no; shift ;;
        -h | --help) usage ;;
        *) echo "install.sh: unknown argument $1" >&2; usage ;;
    esac
done

[ -n "$pinned_release_key" ] ||
    fail "this copy carries no release key; download install.sh from a release page of https://github.com/$public_repository"

case "$(uname -s)-$(uname -m)" in
    Linux-x86_64) platform=linux-x86_64 ;;
    Linux-aarch64 | Linux-arm64) platform=linux-aarch64 ;;
    Darwin-arm64) platform=macos-aarch64 ;;
    *) fail "there is no anet release for $(uname -s) $(uname -m); the previews are for Linux x86-64 and arm64 and macOS on Apple silicon" ;;
esac

sha256_of() {
    if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

# The engine loads these at start; a missing one would only show as a
# service that does not start.
library_is_installed() {
    if command -v ldconfig >/dev/null && ldconfig -p 2>/dev/null | grep -q "$1"; then return 0; fi
    for folder in /lib /lib64 /usr/lib /usr/lib64 /usr/lib/x86_64-linux-gnu /usr/lib/aarch64-linux-gnu; do
        [ -e "$folder/$1" ] && return 0
    done
    return 1
}
if [ "${platform%%-*}" = linux ]; then
    glibc="$(getconf GNU_LIBC_VERSION 2>/dev/null | sed -n 's/^glibc //p')"
    [ -n "$glibc" ] || fail "this Linux has no glibc; the releases need glibc 2.34 or later"
    [ "$(printf '%s\n2.34\n' "$glibc" | sort -V | head -n 1)" = 2.34 ] ||
        fail "this Linux has glibc $glibc; the releases need 2.34 or later (RHEL 9, Debian 12, Ubuntu 22.04 and later)"
    missing=""
    library_is_installed libgomp.so.1 || missing="$missing libgomp.so.1 (Debian and Ubuntu: libgomp1; Fedora and RHEL: libgomp)"
    library_is_installed libvulkan.so.1 || missing="$missing libvulkan.so.1 (Debian and Ubuntu: libvulkan1; Fedora and RHEL: vulkan-loader)"
    [ -z "$missing" ] || fail "install these libraries first:$missing"
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

if [ -n "$archive" ]; then
    [ -f "$archive" ] || fail "$archive is not a file"
    file_name="$(basename "$archive")"
    pattern="^anet-([1-9][0-9]*)-$platform\\.tar\\.gz$"
    [[ "$file_name" =~ $pattern ]] || fail "$file_name is not an anet archive for $platform"
    release="${BASH_REMATCH[1]}"
    [ -f "$archive.sha256" ] || fail "$archive.sha256 is missing; carry it in with the archive"
    cp "$archive" "$archive.sha256" "$work/"
    if [ "$check_provenance" = yes ]; then
        [ -n "$bundle" ] && [ -f "$bundle" ] || fail "an offline install needs --bundle <$file_name.sigstore.json>"
        [ -n "$trusted_root" ] && [ -f "$trusted_root" ] || fail "an offline install needs --trusted-root <Sigstore's trusted_root.json>"
    fi
else
    command -v curl >/dev/null || fail "curl is needed to download the release"
    if [ -z "$release" ]; then
        latest="$(curl -fsSL "https://api.github.com/repos/$public_repository/releases?per_page=1")" ||
            fail "cannot reach the release page of $public_repository"
        release="$(printf '%s' "$latest" | sed -n 's/.*"tag_name": *"release-\([0-9][0-9]*\)".*/\1/p' | head -n 1)"
        [ -n "$release" ] || fail "no release found on $public_repository"
    fi
    case "$release" in '' | *[!0-9]* | 0*) fail "--release must be a positive whole number, not $release" ;; esac
    file_name="anet-$release-$platform.tar.gz"
    base="https://github.com/$public_repository/releases/download/release-$release"
    for file in "$file_name" "$file_name.sha256" "$file_name.sigstore.json"; do
        curl -fsSL -o "$work/$file" "$base/$file" || fail "cannot download $base/$file"
    done
    bundle="$work/$file_name.sigstore.json"
fi

expected="$(cut -d' ' -f1 "$work/$file_name.sha256")"
[ "$(sha256_of "$work/$file_name")" = "$expected" ] || fail "$file_name does not match its SHA-256; do not install it"

# The signing certificate must name the release workflow of the source
# repository at this release's own tag.
workflow_identity="https://github.com/$source_repository/.github/workflows/release.yml@refs/tags/release-$release"
if [ "$check_provenance" = yes ]; then
    command -v cosign >/dev/null || fail "cosign (https://docs.sigstore.dev/cosign/system_config/installation/) is needed to check that $file_name was signed by Antinet's release workflow. Check it by hand with
  cosign verify-blob $file_name --bundle $file_name.sigstore.json --certificate-identity $workflow_identity --certificate-oidc-issuer https://token.actions.githubusercontent.com
or run install.sh with --no-provenance to install it unchecked"
    verify=(cosign verify-blob "$work/$file_name" --bundle "$bundle"
        --certificate-identity "$workflow_identity"
        --certificate-oidc-issuer https://token.actions.githubusercontent.com)
    [ -n "$trusted_root" ] && verify+=(--trusted-root "$trusted_root")
    "${verify[@]}" >/dev/null 2>&1 || fail "$file_name was not signed by $source_repository's release workflow for release $release; do not install it"
    echo "install.sh: $file_name was signed by $source_repository's release workflow for release $release" >&2
else
    echo "install.sh: UNCHECKED INSTALL: the signature of $file_name was not checked" >&2
fi

# The archive must hold exactly one folder of plain relative paths.
top_level="$(tar -tzf "$work/$file_name" | cut -d/ -f1 | sort -u)"
[ "$top_level" = "anet-$release-$platform" ] || fail "$file_name does not hold only anet-$release-$platform/"
tar -tzf "$work/$file_name" | grep -qE '(^/|(^|/)\.\.(/|$))' && fail "$file_name holds a path outside its folder"
tar -C "$work" -xzf "$work/$file_name"
folder="$work/anet-$release-$platform"

# `anet version` run from the folder checks every file against the release
# key compiled into it (specs/0054 REL-3 and REL-10).
printed="$("$folder/anet" version)" || fail "the release does not verify: $printed"
printf '%s\n' "$printed" | grep -qx "release $release (.*)" || fail "the folder is not release $release: $printed"
printf '%s\n' "$printed" | grep -qxF "release key $pinned_release_key" ||
    fail "the release carries another release key than the one this script pins: $printed"

if [ "$platform" = macos-aarch64 ]; then
    releases="$HOME/.local/share/anet/releases"
    mkdir -p "$releases" "$HOME/.local/bin"
    [ -e "$releases/$release" ] && fail "$releases/$release already exists"
    mv "$folder" "$releases/$release"
    ln -sfn "$releases/$release" "$HOME/.local/share/anet/current.new"
    mv -f "$HOME/.local/share/anet/current.new" "$HOME/.local/share/anet/current"
    ln -sfn "$HOME/.local/share/anet/current/anet" "$HOME/.local/bin/anet"
    "$HOME/.local/bin/anet" version
    cat >&2 <<EOF
install.sh: anet release $release is installed for this account.
  Set up a site once:  anet setup
  Run the service:     anet serve
(~/.local/bin must be on PATH.)
EOF
    exit 0
fi

as_root=()
[ "$(id -u)" = 0 ] || as_root=(sudo)
if [ -e /opt/anet/current ]; then
    # The installed engine checks the new release with its own key (REL-6).
    "${as_root[@]}" /opt/anet/current/anet update "$folder"
else
    "${as_root[@]}" "$folder/anet" service install
fi
echo "install.sh: anet release $release is installed and running" >&2
