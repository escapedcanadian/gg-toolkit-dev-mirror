#!/bin/bash
# Generate the concurrency ladder from the project's own ops.yaml.
#
# One file per point, differing ONLY in `concurrency`. Generated rather than committed because the
# base ops.yaml is ~10 KB of configuration and commentary that belongs to the demo, not to the
# benchmark -- nine near-identical copies of it would drift the moment the demo changed.
#
# Total operations in flight at a point = concurrency x (processes per machine) x (machines),
# summed over LAB_ELEMENTS. The harness reports the in-flight it actually achieved, which is the
# number to trust: a client that cannot fill its threads reports fewer, and that is a real result
# rather than a rounding error.
#
# Usage: make-ops.sh <lab.env> <base-ops.yaml> <out-dir> [concurrencies...]
set -u
ENVFILE="$1"; BASE="$2"; OUT="$3"; shift 3
LEVELS="${*:-1 2 4 8 16 32 64 128 256 512}"
# shellcheck disable=SC1090
source "$ENVFILE"
[ -f "$BASE" ] || { echo "no base ops file: $BASE"; exit 1; }
mkdir -p "$OUT"

line=$(grep -nE '^\s*concurrency:\s*[0-9]+' "$BASE" | head -1 | cut -d: -f1)
[ -n "$line" ] || { echo "no 'concurrency:' line in $BASE"; exit 1; }
indent=$(sed -n "${line}p" "$BASE" | sed 's/[^ ].*//')

for c in $LEVELS; do
  sed "${line}s/.*/${indent}concurrency: ${c}/" "$BASE" > "$OUT/c$c.yaml"
  printf '  %-14s concurrency=%s\n' "c$c.yaml" "$(sed -n "${line}p" "$OUT/c$c.yaml" | tr -dc '0-9')"
done
echo "  base: $BASE (concurrency at line $line)"
