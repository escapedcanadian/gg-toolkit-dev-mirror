#!/bin/bash
# Guards that decide whether a measurement is allowed to happen, and whether to believe it.
#
# Every one of these exists because of a specific way a measurement went wrong on the Power lab.
# None of them is defensive programming for its own sake; each cost a day or more before it existed.
# Sourced by bench.sh after lab.env.
#
# ⚠️ This file is run by `#!/bin/bash`, which on macOS is bash 3.2. Empty-array expansion under
# `set -u` errors there and does not in bash 5.x, so `${ARR[@]+"${ARR[@]}"}` is required and is not
# a style choice -- the unguarded form killed a sweep mid-run and stranded four generator processes.

lab_q() {
  # One Prometheus instant query -> a bare number, or nan. Never fails the caller: a monitoring
  # hiccup should discard a run, not abort a sweep.
  curl -s --max-time 15 --data-urlencode "query=$1" "$LAB_PROM/api/v1/query" \
    | python3 -c "import json,sys
r=json.load(sys.stdin)['data']['result']
print(float(r[0]['value'][1]) if r else 'nan')" 2>/dev/null || echo nan
}

lab_active_generators() {
  # Every active generator unit across the estate, as "<host> <unit>" lines.
  for h in $LAB_ALL_HOSTS; do
    $LAB_SSH "root@$h" \
      'systemctl list-units "gridgain-datagen-*" --state=active --no-legend --plain 2>/dev/null | awk "{print \$1}"' \
      2>/dev/null | sed "s|^|$h |"
  done
}

lab_require_quiet() {
  # A HARD STOP, not a discard.
  #
  # A leaked generator does not fail anything: throughput stays plausible, spreads stay tight, and
  # Little's law still passes. It simply rescales every number, invisibly, because metric selectors
  # are per run id. One such run added ~35,000 ops/s for 4h31m before anyone noticed, and a second
  # incident stranded four processes at ~300% CPU each when a teardown reported success without
  # stopping them. Checking the machines is the only reliable signal -- the run record is not
  # evidence, in either direction.
  local found; found=$(lab_active_generators)
  if [ -n "$found" ]; then
    echo "  ABORT: generators already running — every measurement would include their load:"
    printf '    %s\n' "$found"
    echo "  Recover with: for u in \$(systemctl list-units 'gridgain-datagen-*' --state=active" \
         "--no-legend --plain | awk '{print \$1}'); do systemctl stop \"\$u\"; done"
    return 1
  fi
  return 0
}

lab_region_pct() {
  # Percent of the data region in use, max across nodes. With persistence off this is a hard wall:
  # Ignite fails writes with IgniteOutOfMemoryException rather than degrading, and both nodes of the
  # Power lab halted that way once.
  lab_q 'max(100*io_dataregion_default_OffheapUsedSize/io_dataregion_default_MaxSize)' \
    | python3 -c "import sys; v=sys.stdin.read().strip(); print(int(float(v)) if v not in ('','nan') else 0)"
}

lab_client_rtt() {
  # The kernel's MINIMUM observed TCP round trip to the cluster, in ms, from the first client.
  #
  # minrtt and not rtt: the smoothed `rtt` is inflated by delayed ACKs (ato:40) and read ~0.12 ms on
  # a path whose whole application `get` was 0.081 ms -- it cannot be a network round trip. minrtt
  # is the fastest the kernel actually saw, which is the floor of the wire and the number a latency
  # decomposition needs.
  #
  # ⚠️ Match `minrtt:` specifically. A naive /rtt:[0-9.]+/ also matches `rcv_rtt:` (seen at 244 ms)
  # and reported a 72 ms average for a sub-millisecond path.
  local h; h=$(echo $LAB_CLIENTS | awk '{print $1}')
  $LAB_SSH "root@$h" \
    "ss -ti state established '( dport = :$LAB_CLIENT_PORT )' 2>/dev/null | grep -oE 'minrtt:[0-9.]+' | cut -d: -f2" \
    2>/dev/null | python3 -c "
import sys
v=[float(x) for x in sys.stdin.read().split() if x]
print(f'{sum(v)/len(v):.3f}' if v else 'nan')" 2>/dev/null || echo nan
}

lab_reset_cache() {
  # Empty the dataset so each data point starts from the same place.
  #
  # Three things here are load-bearing, all learned the hard way:
  #   - JAVA_HOME. control.sh does not inherit one over ssh and exits with a help message about
  #     downloading a JDK; piping that to /dev/null made the reset a silent no-op.
  #   - --host/--port. Without them control.sh reports "Connection to cluster failed", because the
  #     node binds its advertised address rather than loopback.
  #   - the POST-CONDITION is the cache being gone, NOT the region shrinking. Destroying a cache
  #     does not return its pages to the data region: OffheapUsedSize stays at the high-water mark
  #     and is reused. An earlier version asserted region occupancy and failed a sweep at 16% with
  #     the cache correctly destroyed.
  #
  # `--cache destroy` reports "have been stopped: <name>" and exit 0 whether or not the cache
  # existed, so its output is not an existence check. `--cache list` is.
  local h; h=$(echo $LAB_SERVERS | awk '{print $1}')
  $LAB_SSH "root@$h" "JAVA_HOME=$LAB_JAVA_HOME $LAB_CONTROL \
      --host $h --port $LAB_CONTROL_PORT --cache destroy --caches $LAB_CACHE --yes" >/dev/null 2>&1
  sleep 5
  local caches
  caches=$($LAB_SSH "root@$h" "JAVA_HOME=$LAB_JAVA_HOME $LAB_CONTROL \
             --host $h --port $LAB_CONTROL_PORT --cache list '.*'" 2>&1)
  if printf '%s' "$caches" | grep -qi "$LAB_CACHE"; then
    echo "  [reset] FAILED — the $LAB_CACHE cache still exists after destroy"
    return 1
  fi
  echo "  [reset] cache destroyed; region holds $(lab_region_pct)% of pages (reused, not leaked)"
  return 0
}
