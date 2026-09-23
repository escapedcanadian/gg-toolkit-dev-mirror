#!/bin/bash
# One data point: N runs of one ops file, median throughput reported, invalid runs discarded.
#
# Usage:  bench.sh <lab.env> <label> <ops-file> [runs] [warmup-s] [window]
#
# Starts every element in LAB_ELEMENTS (one `dataGenerate` each, so one run id and run group each),
# unions their metrics, and tears them all down. A point counts only if EVERY element started --
# a half-started point silently measures a smaller client fleet and looks like a legitimate result.
set -u

ENVFILE="$1"; LABEL="$2"; OPS="$3"
[ -f "$ENVFILE" ] || { echo "no such lab file: $ENVFILE"; exit 1; }
# shellcheck disable=SC1090
source "$ENVFILE"
RUNS="${4:-$LAB_RUNS}"; WARMUP="${5:-$LAB_WARMUP}"; WINDOW="${6:-$LAB_WINDOW}"
source "$(dirname "$0")/labguard.sh"
cd "$LAB_PROJECT" || exit 1

# Each point begins from a quiet estate and an empty dataset. Both are hard stops: a stale
# generator or a failed reset does not make a run fail, it makes every run after it wrong.
lab_require_quiet || exit 1
lab_reset_cache   || exit 1

printf '### %s  (ops=%s, %s runs x %ss, %s window, elements: %s)\n' \
  "$LABEL" "$(basename "$OPS")" "$RUNS" "$WARMUP" "$WINDOW" "$LAB_ELEMENTS"

start_one() {
  # Retry once and SAY WHY. An early version swallowed start failures as a one-line "FAILED TO
  # START" and lost three of four points in a sweep with nothing diagnosable.
  local el="$1" out rid
  for attempt in 1 2; do
    out=$(./gradlew dataGenerate --mode=hosts --dataGenerator="$el" \
            --targetCluster="$LAB_CLUSTER" --scenario="$LAB_SCENARIO" --ops="$OPS" \
            -PdemoConfigFile="$LAB_CONFIG" --console=plain 2>&1)
    rid=$(printf '%s' "$out" | grep -oE "run:      [0-9TZ]+" | awk '{print $2}')
    [ -n "$rid" ] && { printf '%s' "$rid"; return 0; }
    printf '%s' "$out" | grep -iE 'what went wrong|error|refus|unreach|timed out' \
      | head -2 | tr '\n' ' ' | cut -c1-200 >&2
    sleep 20
  done
  return 1
}

teardown_all() {
  # ${ARR[@]+"${ARR[@]}"} — see the warning in labguard.sh. The unguarded form aborts under
  # bash 3.2 when the array is empty, which is exactly the path a failed start takes, and it
  # killed the script before this very function could run.
  for rid in ${RIDS[@]+"${RIDS[@]}"}; do
    ./gradlew dataGeneratorTeardown -PrunId="$rid" -PdemoConfigFile="$LAB_CONFIG" \
      --console=plain -q >/dev/null 2>&1
  done
}

results=()
for i in $(seq 1 "$RUNS"); do
  # Re-checked before EVERY run, not once per point: the teardown at the bottom of this loop is the
  # thing that has failed, and when it does, runs 2 and 3 silently include the leftover's load.
  lab_require_quiet || exit 1

  RIDS=()
  for el in $LAB_ELEMENTS; do
    rid=$(start_one "$el" 2>/tmp/bench.err) || { echo "  run $i: '$el' FAILED TO START — $(cat /tmp/bench.err)"; break; }
    RIDS+=("$rid")
  done
  want=$(echo $LAB_ELEMENTS | wc -w | tr -d ' ')
  if [ ${#RIDS[@]} -ne "$want" ]; then
    teardown_all
    echo "  run $i: DISCARDED — only ${#RIDS[@]} of $want elements started"
    continue
  fi

  t0=$(date +%s)
  until [ $(( $(date +%s) - t0 )) -ge "$WARMUP" ]; do sleep 15; done

  # One selector spanning every element's processes.
  alt=$(IFS='|'; echo "${RIDS[*]/%/.*}")
  sel="{service_instance_id=~\"$alt\"}"
  tput=$(lab_q "sum(rate(data_generator_op_count_total$sel[$WINDOW]))")
  flight=$(lab_q "sum(data_generator_in_flight$sel)")
  lat=$(lab_q "sum(rate(data_generator_op_latency_nanoseconds_sum$sel[$WINDOW]))/sum(rate(data_generator_op_latency_nanoseconds_count$sel[$WINDOW]))/1e6")
  put=$(lab_q "sum(rate(data_generator_op_latency_nanoseconds_sum${sel%\}},op=\"put\"}[$WINDOW]))/sum(rate(data_generator_op_latency_nanoseconds_count${sel%\}},op=\"put\"}[$WINDOW]))/1e6")
  get=$(lab_q "sum(rate(data_generator_op_latency_nanoseconds_sum${sel%\}},op=\"get\"}[$WINDOW]))/sum(rate(data_generator_op_latency_nanoseconds_count${sel%\}},op=\"get\"}[$WINDOW]))/1e6")
  srv=""
  for h in $LAB_SERVERS; do
    srv="$srv$(lab_q "sum(rate(node_cpu_seconds_total{instance=\"$h:9100\",mode!=\"idle\"}[3m]))" | cut -c1-4)/"
  done
  repl=$(lab_q 'max(io_dataregion_default_PagesReplaceRate)')
  regpct=$(lab_region_pct)
  rtt=$(lab_client_rtt)
  rows=$(lab_q "sum(cache_${LAB_CACHE}_CacheSize)")

  line=$(python3 -c "
t,f,l,pu,ge,rp,rw = [float(x) for x in '$tput $flight $lat $put $get $repl $rows'.split()]
# Little's law: in-flight / latency must reproduce throughput. Catches a sample taken across a
# restart or against a partly-dead fleet.
implied = f/(l/1000.0) if l>0 else 0
err = abs(implied-t)/t*100 if t>0 else 999
ok = 'ok' if err <= $LAB_LITTLE_TOLERANCE else 'DISCARD'
# Independent of Little's law, which every thrashing run passed: a non-zero replace rate means the
# run measured the disk, not the variable under test.
if rp > 0: ok = 'THRASH'
if $regpct > $LAB_REGION_LIMIT: ok = 'REGION'
print(f'{t:.0f}|{f:.0f}|{l:.3f}|{pu:.3f}|{ge:.3f}|{err:.0f}|{ok}|{rp:.0f}|{rw/1e6:.1f}')
" 2>/dev/null || echo "nan|nan|nan|nan|nan|999|DISCARD|nan|nan")

  IFS='|' read -r t f l pu ge err ok rp rw <<< "$line"
  printf '  run %d: %9s ops/s | flight %5s | mean %7s ms | put %6s | get %6s | rtt %6s | srv %s | little %3s%% | repl %8s | %6sM rows %-7s\n' \
    "$i" "$t" "$f" "$l" "$pu" "$ge" "$rtt" "$srv" "$err" "$rp" "$rw" "$ok"
  [ "$ok" = "ok" ] && results+=("$t")

  teardown_all
done

if [ ${#results[@]} -gt 0 ]; then
  printf '%s\n' "${results[@]}" | python3 -c "
import sys,statistics
v=sorted(float(x) for x in sys.stdin)
sp = (max(v)-min(v))/statistics.median(v)*100 if len(v)>1 else 0
print(f'  => MEDIAN {statistics.median(v):,.0f} ops/s  from {len(v)} valid run(s), spread {sp:.0f}%')"
else
  echo "  => NO VALID RUNS"
fi
echo
