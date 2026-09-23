# GridGain throughput / latency benchmark

A measurement harness for "how fast is this cluster, and at what latency", built against an IBM
Power11 lab in September 2026 and parameterised so it can be pointed at other hardware.

The point of this directory is **comparability**. Numbers from two sites are only comparable if the
protocol and the guards are identical, and most of what follows exists because a measurement was
wrong in a way that looked right.

---

## Running it

```bash
cd benchmark
cp lab.env.example lab.env.intel        # edit: machines, element names, paths
./make-ops.sh lab.env.intel ../src/main/resources/generator/ops.yaml ops 1 2 4 8 16 32 64 128
./bench.sh lab.env.intel "128 in flight" ops/c32.yaml
```

One `bench.sh` invocation is one data point: it starts every element in `LAB_ELEMENTS`, waits
`LAB_WARMUP`, samples a `LAB_WINDOW` range ending there, tears everything down, and repeats
`LAB_RUNS` times. It prints each run and the median.

A sweep is a shell loop over ops files. Keep the points in one script so the whole sweep is one
artefact, and **repeat the first point last** — see below.

Percentiles come from a separate feed:

```bash
python3 -m venv hdrvenv && hdrvenv/bin/pip install hdrhistogram
ssh root@$LAB_MONITOR "$LAB_KAFKA_CONSUMER --bootstrap-server $LAB_KAFKA \
  --topic datagen-metrics --consumer-property group.id=probe-$$" > metrics.jsonl &
hdrvenv/bin/python hdr.py metrics.jsonl
```

---

## The protocol, and why each part is there

| Rule | Why |
|---|---|
| **3 runs per point, median reported** | Single samples on this workload varied ±40%. One sample is not a measurement. |
| **Sample a 3-minute window ending 5 minutes in** | JIT, and the first OTLP export, are not steady state. |
| **Discard on Little's law** (in-flight ÷ latency vs throughput, >25%) | Catches a sample taken across a restart or against a partly-dead fleet. |
| **Discard on `PagesReplaceRate` > 0** | A thrashing data region measures the disk, not the variable under test. **Little's law does not catch this** — every affected run passed it. |
| **Discard above `LAB_REGION_LIMIT`% region** | With persistence off the region is a hard wall: Ignite fails writes rather than degrading. Both Power nodes halted this way once. |
| **Reset the dataset between points** | Otherwise a sweep in ascending order grows its own dataset and produces a convincing, entirely fictional concurrency curve. |
| **Quiet-estate check before *every* run** | A leaked generator does not fail anything — it silently rescales everything. |
| **Repeat the first data point last** | The only thing that has ever caught a drifting sweep. Tight run-to-run spread proves only that runs near each other in time agree. |

If the repeated first point does not reproduce, **the sweep is void**. That check invalidated a
full day of measurement that otherwise looked clean (spreads of 1–6%).

---

## Traps that cost days

Ordered by how much time each consumed before it was understood.

1. **A load generator's own GC lands inside the latency it reports.** The generator times each
   operation client-side, so its pauses become "the cluster's" p99.9. With no heap set, OpenJ9
   defaulted to 8 MB growing to 15.4 GB with a 3.9 GB nursery and paused for ~1 s; the servers
   logged no long pause through the same runs. A fixed 2 GB heap took p99.9 from 4.27 ms to
   0.511 ms **and** returned 6% more throughput. Set `host_jvm_opts` on the generator element.
2. **A leaked generator run is invisible.** One ran for 4 h 31 m at ~35,000 ops/s, outside every
   measurement window, because Prometheus selectors are per run id. `lab_require_quiet` is the fix.
3. **A deploy that detects config drift skips the element and still exits 0.** Automation that
   checks the return code measures a stale deployment. Verify the rendered artefact instead, or use
   `-PforceRedeploy=true`.
4. **`dataGeneratorTeardown` can mark a run `completed` while its processes keep running**, and
   then refuses to act. Recovery is `systemctl stop` per unit on each machine.
5. **`pgrep -f <pattern>` matches the SSH command line carrying the pattern**, reporting processes
   on machines that have none. Use `systemctl list-units` and `systemctl show -p MainPID`.
6. **`/bin/bash` on macOS is 3.2**, which errors on `"${ARR[@]}"` for an empty array under `set -u`
   where bash 5.x does not. The unguarded form killed a sweep and stranded four generator processes.
7. **`ss -ti` has three fields matching `/rtt:/`** — `rtt:`, `rcv_rtt:` and `minrtt:`. Averaging all
   three reported 72 ms for a path whose whole application round trip was 0.081 ms. Use `minrtt`.
8. **Prometheus cannot give you percentiles here.** `data_generator_op_latency_nanoseconds_bucket`
   looks usable but its largest finite bucket is 0.01 ms, so anything slower lands in `+Inf`. Use
   the Kafka HdrHistogram (`hdr.py`) — and note it is in **microseconds**.
9. **Destroying a cache does not shrink the data region.** Pages stay at the high-water mark and are
   reused, so "region back to 0%" is the wrong post-condition for a reset. Assert the cache is gone.

---

## What to change for different hardware

Everything site-specific is in `lab.env.*`. Beyond that, these are the things that are **not**
portable and must be re-derived rather than copied:

| Power11-specific | What to do elsewhere |
|---|---|
| **SMT=8** — 8 cores present as 64 logical CPUs. Aggregate CPU% badly understates physical core busyness, and the licensed CPU count is 64 per 8-core LPAR. | On x86 with HT, the factor is 2. Check `lscpu` and map logical CPUs to cores before reading any CPU figure. |
| **`lparstat`** gives PURR-based utilisation; `mpstat`/`pidstat`/`perf` are absent. | On Intel use `mpstat -P ALL` and `perf`. The harness deliberately uses only node_exporter and `/proc`, which exist everywhere. |
| **`ibmveth`** virtual NIC: no interrupt coalescing, GRO off, LRO fixed off. Min RTT 11–22 µs. | A physical Intel NIC has coalescing and offloads that trade latency for CPU. Measure `minrtt` first — it bounds what any software tuning can win. |
| **`pseries_idle`** with `CEDE` (12 µs exit). | Intel uses `intel_idle` with deeper C-states, often far more than 12 µs. At low utilisation this is a real latency contributor; check `/sys/devices/system/cpu/cpu0/cpuidle/state*/latency`. |
| **IBM Semeru (OpenJ9)** — the ppc64le JDK. Silently ignores unrecognised `-XX:` flags; `-XX:+UseG1GC` is rejected. | On x86 you will likely run HotSpot, where HotSpot tuning applies and OpenJ9 flags (`-Xgcpolicy`, `-Xmn`) do not. **This alone makes JVM settings non-comparable** unless both sides run the same JVM. |
| **ppc64le distributions** in `demo-config.yaml` (`distributions.*.artifacts.ppc64le`). | Needs `x86_64` artifacts. The toolkit selects by the host's `architecture` field. |

**The single most important control for a cross-architecture comparison** is the JVM. Semeru/OpenJ9
on Power against Temurin/HotSpot on Intel compares two runtimes as much as two CPUs. Temurin
publishes ppc64le builds, so running HotSpot on both sides is achievable and worth the effort.

---

## Power11 baseline to compare against

Two-node cluster, `backups: 1`, `FULL_SYNC`, persistence off, 32 GiB region, generator on a fixed
2 GB heap. Latency in milliseconds. Full analysis in `../power-lab-report.md`.

**Low-latency profile** — 2 client processes on one machine:

| in flight | ops/s | mean | get | put | p50 | p99 | p99.9 |
|---|---:|---:|---:|---:|---:|---:|---:|
| 2 | 14,860 | 0.133 | 0.079 | 0.187 | 0.151 | 0.219 | 0.258 |
| 8 | 42,228 | 0.185 | 0.129 | 0.240 | 0.190 | 0.366 | 0.411 |
| 32 | 128,241 | 0.214 | 0.144 | 0.284 | 0.217 | 0.421 | 0.511 |

**Throughput profile** — 4 client processes across three machines:

| in flight | ops/s | mean | get | put |
|---|---:|---:|---:|---:|
| 128 | 220,712 | 0.529 | 0.222 | 0.835 |

**Thread-pool sizing** (`host_thread_pools.client_connector`, per node) — the largest single lever
found, and non-monotonic:

| pool/node | 512 in flight | 1024 in flight |
|---|---:|---:|
| 64 (Ignite default = availableProcessors) | 206,393 | — |
| **256** | **289,568** | **304,789** |
| 512 | 227,690 | ~299,000 |

Peak throughput went from 220,712 to ~305,000 ops/s by sizing one thread pool, with **no change to
core count**. 512 per node is worse than 256 while using *less* server CPU — thread thrashing, not a
GridGain limit. Expect the optimum to differ on other hardware; it is a tuning parameter with a
peak, not a lever to turn up.

**Not the bottleneck at peak**, all measured under load: disk (0 KB/s, persistence off), network
(76 Mbps of 1 Gb; 11–22 µs min RTT), server CPU (~17 of 64, 26%), memory (51 GB free, no swap),
page eviction (0), server GC (mean 4.4 ms, no pause over 50 ms).
