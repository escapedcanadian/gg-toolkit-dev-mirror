#!/bin/sh
# Encrypts secrets/demo-secrets.yaml into secrets/demo-secrets.sops.yaml and removes the plaintext.
#
# For the bulk-editing path only. Prefer `sops secrets/demo-secrets.sops.yaml`, which edits in place and
# never writes plaintext to disk at all; this exists for when you would rather work in a plain file.
#
# The two names differ on purpose: `.sops.` means encrypted, `.gitignore` denies the plaintext name, and
# this script is what moves content from one to the other.
set -eu

plaintext=secrets/demo-secrets.yaml
encrypted=secrets/demo-secrets.sops.yaml

[ -f "$plaintext" ] || {
    printf 'ERROR: %s does not exist.\n' "$plaintext" >&2
    printf 'To edit the encrypted file directly (preferred):  sops %s\n' "$encrypted" >&2
    printf 'To produce a plaintext copy for bulk editing:\n' >&2
    printf '    sops --decrypt %s > %s\n' "$encrypted" "$plaintext" >&2
    exit 1
}

if grep -qE '^sops:' "$plaintext"; then
    printf 'ERROR: %s already looks encrypted (it has a sops: block).\n' "$plaintext" >&2
    printf 'Nothing to do. If you meant to edit it:  sops %s\n' "$encrypted" >&2
    exit 1
fi

if grep -q 'replace-me' "$plaintext"; then
    printf 'WARNING: %s still contains placeholder values ending in -replace-me.\n' "$plaintext" >&2
    printf '         Encrypting anyway, but a deployment using them will fail to authenticate.\n\n' >&2
fi

# To a temporary first, then renamed: an interrupted encrypt must not leave a truncated file under the
# name that everything else trusts to be complete and encrypted.
tmp="$encrypted.tmp.$$"
trap 'rm -f "$tmp"' EXIT
sops --encrypt --input-type yaml --output-type yaml "$plaintext" > "$tmp" || {
    printf 'ERROR: sops could not encrypt %s.\n' "$plaintext" >&2
    printf 'If it reported "no creation rules", .sops.yaml is missing or has no rule for secrets/.\n' >&2
    printf 'That is about a missing public recipient, not about SOPS_AGE_KEY_FILE.\n' >&2
    printf 'Run ./scripts/bootstrap-secrets.sh to set it up.\n' >&2
    exit 1
}

grep -qE '^sops:' "$tmp" || { printf 'ERROR: the encrypt produced no sops: block. Refusing.\n' >&2; exit 1; }

chmod 600 "$tmp"
mv "$tmp" "$encrypted"
trap - EXIT
printf 'Encrypted -> %s\n' "$encrypted"

# The plaintext goes, because leaving it is how the incident this scheme prevents actually happened. It
# is gitignored, so it would not be committed — but it would still be sitting on the disk.
rm -f "$plaintext"
printf 'Removed the plaintext %s\n' "$plaintext"
printf '\nTo edit again without a plaintext copy:  sops %s\n' "$encrypted"
