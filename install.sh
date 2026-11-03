#!/usr/bin/env sh
# Installs the Swale CLI for this action. It checks the release manifest's
# signature against Swale's key, whose fingerprint is below, then the binary's
# SHA-256 against the manifest, and installs nothing if either fails. See
# README.md.
#
# POSIX sh, so that it runs in containers without bash; on Windows, Git Bash
# runs it.

set -eu

FINGERPRINT="F52CF38130C597453BE6BD7DD65BF0C473F6E965"
KEY_URL="https://swale.io/.well-known/pgp-key.txt"
RELEASES="https://github.com/swaleio/swale-cli/releases"

# printf throughout: dash's echo, sh on Debian and Ubuntu, rewrites backslash
# sequences.
die() { printf '::error title=setup-swale::%s\n' "$*"; exit 1; }
need() { command -v "$1" >/dev/null 2>&1; }

need curl || need wget || die "needs curl or wget."
need sha256sum || need shasum || die "needs sha256sum or shasum."
need gpg || die "needs gpg to verify the release signature. Install it first, for example with 'apt-get install -y gnupg' or 'apk add gnupg'."

fetch() {
  # $1 url, $2 destination.
  if need curl; then
    curl -fsSL --retry 3 "$1" -o "$2" || return 1
  else
    wget -qO "$2" "$1" || return 1
  fi
}

sha256_of() {
  if need sha256sum; then sha256sum "$1" | cut -d ' ' -f 1
  else shasum -a 256 "$1" | cut -d ' ' -f 1
  fi
}

# The input is never printed, so a line break in it can't start a second
# workflow command. grep reads line by line, so the case vets every character.
requested="${INPUT_VERSION:-latest}"
requested="${requested#v}"
case "$requested" in
  latest) base="$RELEASES/latest/download" ;;
  *[!0-9A-Za-z.-]* | "") die "the version input is not a version like 1.0.1, or latest." ;;
  *)
    printf '%s\n' "$requested" | grep -Eq '^[0-9]+[.][0-9]+[.][0-9]+(-[0-9A-Za-z.-]+)?$' \
      || die "the version input is not a version like 1.0.1, or latest."
    base="$RELEASES/download/v$requested"
    ;;
esac

# The runner's own names for its platform, which hold in containers too.
case "${RUNNER_OS:-}" in
  Linux) os_part="linux" ;;
  macOS) os_part="osx" ;;
  Windows) os_part="win" ;;
  *) die "unsupported runner OS '${RUNNER_OS:-}'." ;;
esac
case "${RUNNER_ARCH:-}" in
  X64) arch_part="x64" ;;
  ARM64) arch_part="arm64" ;;
  *) die "unsupported runner architecture '${RUNNER_ARCH:-}'." ;;
esac

# musl systems take the musl build: Alpine, or musl's loader without glibc's.
# Debian's musl package puts musl's loader beside glibc, which stays the libc.
if [ "$os_part" = "linux" ]; then
  case "$arch_part" in
    x64) glibc_loader=/lib64/ld-linux-x86-64.so.2 ;;
    arm64) glibc_loader=/lib/ld-linux-aarch64.so.1 ;;
  esac
  if [ -f /etc/alpine-release ] || { ls /lib/ld-musl-*.so.1 >/dev/null 2>&1 && [ ! -e "$glibc_loader" ]; }; then
    os_part="linux-musl"
  fi
fi
RID="${os_part}-${arch_part}"

# On Windows, Git Bash paths here, and Windows paths for what the runner reads.
root="${RUNNER_TEMP:?RUNNER_TEMP is not set; run this as a GitHub Actions step.}"
if [ "$os_part" = "win" ]; then
  root=$(cygpath -u "$root")
fi
runner_path() {
  if [ "$os_part" = "win" ]; then cygpath -w "$1"; else printf '%s\n' "$1"; fi
}

tmp=$(mktemp -d "$root/setup-swale.XXXXXX")
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT INT TERM

printf 'Resolving %s from %s\n' "$RID" "$base"
fetch "$base/manifest.json" "$tmp/manifest.json" || die "no release found at $base."
fetch "$base/manifest.json.sig" "$tmp/manifest.json.sig" || die "the release at $base has no signature."
fetch "$KEY_URL" "$tmp/key.asc" || die "could not fetch the signing key from $KEY_URL."

# gpg fails the import when its agent's socket path is too long, though the key
# is imported, so the key list below decides.
GNUPGHOME="$tmp/gnupg"
export GNUPGHOME
mkdir -p "$GNUPGHOME"
chmod 700 "$GNUPGHOME"
gpg --batch --quiet --import "$tmp/key.asc" >/dev/null 2>&1 || true
gpg --batch --list-keys --with-colons 2>/dev/null | grep -q "^fpr:::::::::${FINGERPRINT}:" \
  || die "the key at $KEY_URL is not $FINGERPRINT."
verify_status=$(gpg --batch --status-fd 1 --verify "$tmp/manifest.json.sig" "$tmp/manifest.json" 2>/dev/null) \
  || die "the release signature is not valid."
# The signer must be this key or its subkey, whichever keys the fetched file
# holds: VALIDSIG ends with the signer's primary.
printf '%s\n' "$verify_status" | grep -q "^\[GNUPG:\] VALIDSIG .* ${FINGERPRINT}\$" \
  || die "the release is not signed by $FINGERPRINT."
# gpg exits 0 for a revoked key. An expired subkey still verifies older releases.
if printf '%s\n' "$verify_status" | grep -q '^\[GNUPG:\] REVKEYSIG '; then
  die "the release is signed by a revoked key."
fi
printf 'Signature verified against %s\n' "$FINGERPRINT"

# Read with sed, after the signature: a minimal container has no JSON parser.
block=$(tr -d ' \n\r' < "$tmp/manifest.json" | sed -n "s/.*\"$RID\":{\([^}]*\)}.*/\1/p")
[ -n "$block" ] || die "the release carries no build for $RID."
checksum=$(printf '%s\n' "$block" | sed -n 's/.*"checksum":"\([^"]*\)".*/\1/p')
asset=$(printf '%s\n' "$block" | sed -n 's/.*"asset":"\([^"]*\)".*/\1/p')
version=$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$tmp/manifest.json" | sed -n 1p)
if [ -z "$checksum" ] || [ -z "$asset" ] || [ -z "$version" ]; then
  die "the manifest entry for $RID is malformed."
fi

# Another release's signed manifest must not pass under this one's tag.
if [ "$requested" != "latest" ] && [ "$version" != "$requested" ]; then
  die "the release v$requested carries the manifest of $version."
fi

printf 'Downloading %s (%s)\n' "$asset" "$version"
fetch "$base/$asset" "$tmp/$asset" || die "could not download $asset."
actual=$(sha256_of "$tmp/$asset")
[ "$actual" = "$checksum" ] || die "checksum mismatch for $asset: expected $checksum, got $actual."
printf 'Checksum verified\n'

bin_dir="$root/swale-$version"
bin="$bin_dir/swale"
if [ "$os_part" = "win" ]; then
  bin="$bin.exe"
fi
mkdir -p "$bin_dir"
chmod +x "$tmp/$asset"
mv -f "$tmp/$asset" "$bin"

runner_path "$bin_dir" >> "$GITHUB_PATH"
{
  printf 'version=%s\n' "$version"
  printf 'path=%s\n' "$(runner_path "$bin")"
} >> "$GITHUB_OUTPUT"
printf 'Installed swale %s to %s\n' "$version" "$(runner_path "$bin")"
