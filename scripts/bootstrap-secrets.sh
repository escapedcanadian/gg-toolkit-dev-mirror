#!/bin/sh
# One-time SOPS setup for this demo repo. Idempotent: safe to re-run.
#
# Exists because the manual sequence has a step that is easy to miss and whose omission is silent: SOPS
# needs its own config file, `.sops.yaml`, naming the PUBLIC key to encrypt to. Without it
# `sops --encrypt` fails with "no creation rules", which never mentions public keys — and a plaintext
# secrets file left behind looks exactly like the example it was copied from.
set -eu

say() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

command -v sops >/dev/null 2>&1 || die "sops is not installed. Install it with: brew install sops age"
command -v age-keygen >/dev/null 2>&1 || die "age is not installed. Install it with: brew install sops age"

# --- 1. the private key, which decrypts -------------------------------------------------------------
key_file="${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}"
if [ ! -f "$key_file" ]; then
    say "No age key at $key_file — creating one."
    mkdir -p "$(dirname "$key_file")"
    age-keygen -o "$key_file" >/dev/null 2>&1
    chmod 600 "$key_file"
    say "Created $key_file."
    say ""
    say "Add this to your shell rc so SOPS can find it when decrypting:"
    say "    export SOPS_AGE_KEY_FILE=$key_file"
    say ""
else
    say "Using the age key at $key_file."
fi

# --- 2. the public key, which encrypts --------------------------------------------------------------
public_key=$(age-keygen -y "$key_file")
[ -n "$public_key" ] || die "Could not derive a public key from $key_file."
say "Your public key is $public_key (safe to commit)."

# --- 3. .sops.yaml, the step people miss ------------------------------------------------------------
if [ -f .sops.yaml ] && grep -q "$public_key" .sops.yaml; then
    say ".sops.yaml already lists your public key."
elif [ -f .sops.yaml ]; then
    say ""
    say ".sops.yaml exists but does not list your public key. Left alone rather than edited, because it"
    say "may name a colleague's key deliberately — a file encrypted to several recipients is normal."
    say "Add yours to its 'age:' field if you need to decrypt:"
    say "    $public_key"
else
    [ -f .sops.yaml.example ] || die ".sops.yaml.example is missing from this repo."
    sed "s|age1REPLACE_WITH_YOUR_PUBLIC_KEY|$public_key|" .sops.yaml.example > .sops.yaml
    say "Created .sops.yaml with your public key."
fi

# --- 4. the secrets data file, born encrypted -------------------------------------------------------
# The example is encrypted DIRECTLY into the .sops.yaml form. The plaintext form is never created, so
# there is no window in which a real secrets file sits unencrypted on disk — which is exactly where
# credentials get left behind. Values are placeholders at this point; edit them with `sops`, which also
# never writes plaintext to disk.
# Beside the demo config, because that is the directory the toolkit resolves a secret's
# `source.file` against — the same convention cluster/ and generator/ already follow.
dir=src/main/resources/secrets
plaintext=$dir/demo-secrets.yaml
encrypted=$dir/demo-secrets.sops.yaml
example=$dir/demo-secrets.yaml.example

if [ -f "$encrypted" ]; then
    if grep -q '^sops:' "$encrypted"; then
        say "$encrypted exists and is encrypted."
    else
        die "$encrypted exists but is NOT encrypted. That name is reserved for encrypted content. Move it to $plaintext and run ./scripts/encrypt-secrets.sh"
    fi
else
    [ -f "$example" ] || die "$example is missing from this repo."
    sops --encrypt --input-type yaml --output-type yaml "$example" > "$encrypted" \
        || { rm -f "$encrypted"; die "Could not encrypt $example. If sops reported 'no creation rules', .sops.yaml lacks a rule for $dir — that is about a missing public recipient, not SOPS_AGE_KEY_FILE."; }
    chmod 600 "$encrypted"
    say "Created $encrypted by encrypting the example. It never existed as plaintext."
fi

if [ -f "$plaintext" ]; then
    say ""
    say "NOTE: $plaintext exists. It is gitignored, but it is plaintext — remove it once you have"
    say "      encrypted its contents with ./scripts/encrypt-secrets.sh"
fi

# --- 5. the safety net ------------------------------------------------------------------------------
if [ -d .githooks ]; then
    current=$(git config --get core.hooksPath 2>/dev/null || true)
    if [ "$current" = ".githooks" ]; then
        say "The pre-commit hook is already enabled."
    else
        git config core.hooksPath .githooks
        say "Enabled .githooks/pre-commit, which refuses to commit an unencrypted secrets file."
    fi
fi

say ""
say "Next:"
say "  1. Replace every '-replace-me' value:"
say "         sops $encrypted"
say "     That opens your editor on the decrypted content and re-encrypts on save. No plaintext"
say "     touches the disk."
say "  2. Reference the entries from demo-config.yaml's 'secrets:' section by their top-level key."
say ""
say "Verify at any time with:"
say "  grep -q '^sops:' $encrypted && echo ENCRYPTED || echo PLAINTEXT"
