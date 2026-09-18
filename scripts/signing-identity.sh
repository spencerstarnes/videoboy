#!/bin/bash
#
# signing-identity.sh — make (once) and report a STABLE local code-signing identity.
#
# Purpose : ad-hoc signing (`codesign --sign -`) gives the app a new cdhash on every
#           build. macOS TCC pins each permission grant to a code-signing requirement,
#           for an ad-hoc binary that requirement is literally `cdhash H"..."`. So every
#           rebuild silently voided Screen Recording, Microphone and Camera, and the
#           emulator capture came back black with nothing saying why.
#
#           Signing with a certificate instead makes the requirement certificate-based
#           and therefore STABLE across rebuilds: grant the permission once, keep it.
#
# Outputs : prints the identity name on stdout. Exit 0 means it is usable.
# Connects: scripts/build.sh, which signs with whatever this prints.
#
# This is a SELF-SIGNED, LOCAL-ONLY certificate. It is not an Apple Developer Program
# identity, it is not for distribution, and it is not notarization — all three of which
# CLAUDE.md rules out. It exists only so this machine recognises this app as the same
# app it recognised yesterday.
#
# Idempotent: run it as often as you like. It only builds anything the first time.
#

set -euo pipefail

IDENTITY="Videoboy Local Signing"
KEYCHAIN_NAME="videoboy-signing.keychain-db"
KEYCHAIN="$HOME/Library/Keychains/$KEYCHAIN_NAME"
# The keychain password lives outside the repo: CLAUDE.md says no secrets in the repo,
# and while this one guards nothing more than a self-signed dev certificate, the rule
# is worth keeping simple.
SECRET_DIR="$HOME/.config/videoboy"
SECRET_FILE="$SECRET_DIR/signing-keychain.pw"

note() { printf '\033[1;36m[signing]\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[1;31m[signing]\033[0m %s\n' "$*" >&2; exit 1; }

# `set -e` kills this script at the first non-zero status, and a script that dies
# without saying where is worse than one that does not run at all — the first version
# of this exited silently on a SIGPIPE and read exactly like it had done nothing.
trap 'status=$?; printf "\033[1;31m[signing]\033[0m failed at line $LINENO (exit $status)\n" >&2' ERR

# UNLOCK FIRST, THEN LOOK. The other way round is a bug that only appears after a
# reboot: a locked keychain reports no identities, so the check below concluded there
# was nothing there, tried to create a second one, and failed on the import — leaving
# the build to fall back to ad-hoc with a perfectly good identity sitting on disk.
if [ -s "$SECRET_FILE" ] && [ -f "$KEYCHAIN" ]; then
    security unlock-keychain -p "$(cat "$SECRET_FILE")" "$KEYCHAIN" 2>/dev/null || true
    # Also make sure it is on the search list. A keychain that is not searched is
    # invisible to `find-identity` however unlocked it is.
    EXISTING="$(security list-keychains -d user | sed -e 's/^[[:space:]]*"//' -e 's/"$//')"
    if ! printf '%s\n' "$EXISTING" | grep -qF "$KEYCHAIN_NAME"; then
        # shellcheck disable=SC2086
        security list-keychains -d user -s $(printf '%s\n' "$EXISTING" | tr '\n' ' ') "$KEYCHAIN" 2>/dev/null || true
    fi
fi

# Already present and usable? Say so and stop.
if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$IDENTITY"; then
    echo "$IDENTITY"
    exit 0
fi

note "no stable signing identity yet — creating one (first run only)"

mkdir -p "$SECRET_DIR"
chmod 700 "$SECRET_DIR"

# `-s` not `-f`: an earlier run could leave this EXISTING BUT EMPTY, because the
# redirect creates the file before the command that fills it runs. Testing only for
# existence would then reuse an empty password forever.
if [ ! -s "$SECRET_FILE" ]; then
    # `openssl rand` rather than `tr </dev/urandom | head -c`. That pipeline is the
    # reason the first version of this script died without a word: `head` closes the
    # pipe after 32 bytes, `tr` takes SIGPIPE and exits non-zero, and `pipefail` turns
    # a perfectly successful password into a fatal error.
    openssl rand -hex 24 > "$SECRET_FILE" || fail "could not generate a keychain password"
    chmod 600 "$SECRET_FILE"
fi
[ -s "$SECRET_FILE" ] || fail "the keychain password file is empty: $SECRET_FILE"
KEYCHAIN_PASSWORD="$(cat "$SECRET_FILE")"

WORK="$(mktemp -d -t videoboy-signing)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/openssl.cnf" <<'CNF'
[req]
distinguished_name = dn
x509_extensions    = v3
prompt             = no

[dn]
CN = Videoboy Local Signing

[v3]
basicConstraints     = critical,CA:false
keyUsage             = critical,digitalSignature
extendedKeyUsage     = critical,codeSigning
CNF

note "generating a self-signed code-signing certificate"
openssl req -x509 -newkey rsa:2048 -sha256 -days 7300 -nodes \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
    -config "$WORK/openssl.cnf" 2>/dev/null \
    || fail "openssl could not generate the certificate"

P12_PASSWORD="videoboy"
openssl pkcs12 -export \
    -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -out "$WORK/identity.p12" -name "$IDENTITY" \
    -passout "pass:$P12_PASSWORD" 2>/dev/null \
    || fail "openssl could not package the identity"

# A DEDICATED keychain, not the login one. Importing into login would need the user's
# login password at build time; a keychain we create has a password we already know,
# so the whole thing stays non-interactive.
if [ ! -f "$KEYCHAIN" ]; then
    security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_NAME" \
        || fail "could not create $KEYCHAIN_NAME"
fi
# No auto-lock: a keychain that relocks on a timer turns into a build that fails at
# 2am for no visible reason.
security set-keychain-settings "$KEYCHAIN_NAME"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_NAME"

note "importing the identity"
security import "$WORK/identity.p12" \
    -k "$KEYCHAIN_NAME" -P "$P12_PASSWORD" \
    -T /usr/bin/codesign -A 2>/dev/null \
    || fail "could not import the identity into $KEYCHAIN_NAME"

# Without this, codesign triggers a GUI "allow access to key?" prompt on every build.
security set-key-partition-list \
    -S apple-tool:,apple:,codesign: \
    -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_NAME" >/dev/null 2>&1 || true

# Put it on the search list ALONGSIDE what is already there. `list-keychains -s` REPLACES
# the list, so the existing entries are read back first — dropping the login keychain
# here would break every other tool on the machine that expects to find it.
EXISTING="$(security list-keychains -d user | sed -e 's/^[[:space:]]*"//' -e 's/"$//')"
# Recorded before anything is changed, so the search list is trivially reversible.
# Changing a keychain search list on someone's machine should never be a one-way door.
printf '%s\n' "$EXISTING" > "$SECRET_DIR/keychain-list.before"
note "previous keychain search list saved to $SECRET_DIR/keychain-list.before"
note "to undo everything this script did:"
note "  security list-keychains -d user -s \$(cat '$SECRET_DIR/keychain-list.before' | tr '\\n' ' ')"
note "  security delete-keychain $KEYCHAIN_NAME"
if ! printf '%s\n' "$EXISTING" | grep -qF "$KEYCHAIN_NAME"; then
    # shellcheck disable=SC2086
    security list-keychains -d user -s $(printf '%s\n' "$EXISTING" | tr '\n' ' ') "$KEYCHAIN_NAME"
fi

security find-identity -v -p codesigning 2>/dev/null | grep -qF "$IDENTITY" \
    || fail "the identity was created but codesign cannot see it"

note "created '$IDENTITY' in $KEYCHAIN_NAME"
note "macOS will ask for Screen Recording ONCE more, then the grant sticks across builds"
echo "$IDENTITY"
