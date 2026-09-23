#!/usr/bin/env python3
"""Percentiles for each benchmark point, from the generator's HdrHistogram on Kafka.

Why this exists: Prometheus carries only sum/count for operation latency. It also carries
`data_generator_op_latency_nanoseconds_bucket`, but that histogram's largest finite bucket is
0.01 ms while this workload sits at 0.15-0.3 ms -- every observation lands in +Inf and
`histogram_quantile` returns nothing usable. The generator separately publishes a full
HdrHistogram to the Kafka metrics topic, which is the only route to a real tail.

⚠️ Units are MICROSECONDS. Recorded values run 52 .. 346,623 against a `runAvgLatencyMs` of
0.136, so the scale is microseconds and not the nanoseconds the Prometheus metric name implies.
Dividing by 1e6 silently yields p50 = 0.000 and looks plausible, which is how that was nearly
missed.

The histogram is CUMULATIVE from run start, so the last message of a run includes JIT warm-up and
the first-operation outlier (a 347 ms max was observed that way). Subtracting the histogram at the
window's start from the one at its end gives the interval alone -- matching the window
bench.sh measures throughput over, which is what makes the two comparable.

Usage: hdr.py <metrics-stream.jsonl> [window_start_s] [window_end_s]
       defaults 120 300, i.e. bench.sh's 3-minute window ending at its 300s warm-up mark.
"""
import json
import sys
from collections import defaultdict

from hdrh.histogram import HdrHistogram

US_PER_MS = 1000.0


def interval(end, start):
    """end minus start, bucket by bucket.

    The Python hdrh port has `add` but no `subtract`, so this walks the later histogram's recorded
    buckets and removes the counts the earlier one already held. Counts are per equivalent-value
    bucket, so this is exact at the histogram's own resolution rather than an approximation.
    """
    out = HdrHistogram(end.lowest_trackable_value,
                       end.highest_trackable_value,
                       end.significant_figures)
    for item in end.get_recorded_iterator():
        v = item.value_iterated_to
        delta = item.count_at_value_iterated_to - start.get_count_at_value(v)
        if delta > 0:
            out.record_value(v, delta)
    return out


def pct_line(h, label, indent="  "):
    n = h.get_total_count()
    if n == 0:
        print(f"{indent}{label:<26} (no samples in window)")
        return
    v = lambda p: h.get_value_at_percentile(p) / US_PER_MS
    print(f"{indent}{label:<26} n={n:>11,}  mean={h.get_mean_value()/US_PER_MS:6.3f}  "
          f"p50={v(50):6.3f}  p90={v(90):6.3f}  p99={v(99):6.3f}  "
          f"p99.9={v(99.9):7.3f}  p99.99={v(99.99):7.3f}  max={h.get_max_value()/US_PER_MS:8.3f}")


def main():
    path = sys.argv[1]
    w0 = float(sys.argv[2]) if len(sys.argv) > 2 else 120.0
    w1 = float(sys.argv[3]) if len(sys.argv) > 3 else 300.0

    by_run = defaultdict(list)
    for line in open(path):
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            m = json.loads(line)
        except json.JSONDecodeError:
            continue                      # a truncated tail line while the collector is still writing
        by_run[m["runId"]].append(m)

    # runId is the timestamp the run started, so grouping by its prefix groups a benchmark point's
    # processes together (…-i0, …-i1 share a run group).
    groups = defaultdict(list)
    for rid in by_run:
        groups[rid.rsplit("-i", 1)[0]].append(rid)

    for group in sorted(groups):
        print(f"\n=== run group {group} ===")
        combined = None
        for rid in sorted(groups[group]):
            ms = sorted(by_run[rid], key=lambda m: m["updatedAtMs"])
            t0 = ms[0]["updatedAtMs"]
            start = min(ms, key=lambda m: abs((m["updatedAtMs"] - t0) / 1000.0 - w0))
            end = min(ms, key=lambda m: abs((m["updatedAtMs"] - t0) / 1000.0 - w1))
            span = (end["updatedAtMs"] - start["updatedAtMs"]) / 1000.0
            if span <= 0:
                print(f"  {rid}: run too short for the {w0:.0f}-{w1:.0f}s window "
                      f"({(ms[-1]['updatedAtMs']-t0)/1000.0:.0f}s of data)")
                continue
            h = interval(HdrHistogram.decode(end["runLatencyHistogram"]),
                         HdrHistogram.decode(start["runLatencyHistogram"]))
            pct_line(h, f"{rid}  [{span:.0f}s]")
            if combined is None:
                combined = h
            else:
                combined.add(h)
        if combined is not None and len(groups[group]) > 1:
            pct_line(combined, "COMBINED", indent="  -> ")


main()
