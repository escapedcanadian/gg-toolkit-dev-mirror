# GridGain 8 on IBM Power11

**Performance testing results and learnings.**

Analysis performed by David Brown (david.brown@mariadb.com)

21–23 September 2026

Platform - GridGain 8 v8.9.33

32 GiB region · 3 × Power11 LPAR, 8 cores / SMT 8 / 61.7 GiB, RHEL 9.8 ppc64le

IBM Semeru (OpenJ9)

---

## Architecture

*vm01* and *vm02* were used as a two-node GridGain 8 cluster, using a single 'Customer' cache with an integer primary key and a minimal string body. The cache was configured to have one replica and `FULL_SYNC`. Using a single replica (i.e two local data copies) is the most common configuration used in large GridGain deployments since they often include geo-distributed replicas and therefore a third local data copy does not provide significant failover protection benefit relative to the increase cost, complexity and latency. In addition, because the IBM Power 11 series offers virtual private memory (vPMem) the GridGain local persistence was not used in any of the numbers. It was tested, however to ensure it works and to derive a general impact to the performance, as will be presented later.

A 50/50 read-write key-value workload in which every write waits for its replica on the other
machine was used for this testing. We could test at other ratios, and example latencies will be provided for reads (`gets`) vs writes (`puts`) in the results.

*vm03* was used to run the clients (a.k.a. load generator).
*vm04*, a smaller intel-based machine, was used for hosting Prometheus and Grafana

GridGain's code is designed to dedicate and hold a CPU thread until to the operation completes. This is part of the optimized internal design of GridGain.  The impact of this architectural decision on this test is that we will see increased latencies when the number of client threads exceeds the number of server threads.  This impact is shown in the numbers below.

It is easiest to understand the latency/throughput tradeoff by thinking about the fact that maximum throughput is achieved if there are always operations 'queued up' in the server's network buffer, so there is always an operation for a server to perform as soon as it has completed its previous operation. Those clients, however, will experience longer latency while they 'wait' for an available server thread. Conversely, the lowest latency is experienced if clients never have to wait for a server thread to be available.

**Every number in this report is measured, not scaled or extrapolated.** The servers ran with all
64 vCPUs available throughout (confirmed in each node's startup log: `CPUs=64`). Where additional
client threads were needed beyond what *vm03* alone could supply, generator processes were added on
*vm01* and *vm02* — the servers have ample spare CPU, as the results show, and the client
configuration is stated for every measurement. A separate experiment did cap the servers to 32
vCPUs; its results appear only where explicitly labelled.

---

## Highlights
There is no single answer for 'how fast it is', but 'extremely' is the best summary.

Fastest read performance:  **0.079 ms**  at 14,860 ops/s

Target performance  **128,241 ops/s** while mean latency stays under **¼ ms**

Best practical throughput:  **304,789 ops/s** at 3.09 ms mean

Highest measured:  **313,499 ops/s** — but at 6.15 ms, which is past the point anyone would run

---

## Maximum throughput at each latency budget

This is the table to quote. Pick the latency a demo needs; read off what it can sustain.

| Mean latency budget | Sustained ops/s | Configuration |
|---|---:|---|
| ≤ 0.15 ms | 14,860 | 2 in flight |
| ≤ 0.20 ms | 77,482 | 16 in flight |
| **≤ 0.25 ms** | **128,241** | **32 in flight** |
| ≤ 0.35 ms | 188,617 | 64 in flight, 4 client processes |
| ≤ 0.55 ms | 220,712 | 128 in flight, 4 client processes |
| ≤ 0.90 ms | 244,006 | 256 in flight, request pool 256/node |
| ≤ 1.60 ms | 289,568 | 512 in flight, request pool 256/node |
| ≤ 3.10 ms | 304,789 | 1024 in flight, request pool 256/node |

The middle of that range is unusually cheap. Going from 8 to 32 operations in flight costs **12%
more read latency** and returns **three times the throughput**. The expensive ground is at the two
ends: the last 0.05 ms of latency costs 88% of throughput, and the last 15,000 ops/s costs a
doubling of latency.

---

## Low-latency profile
What throughput would we achieve if our goal were reliable, low latency ...

Two client processes on *vm03*. Percentiles from the generator's HdrHistogram over the same window the throughput is measured in.  Warm up period is excluded.

| In flight | ops/s | mean ms | get ms | put ms | p50 | p99 | p99.9 |
|---|---:|---:|---:|---:|---:|---:|---:|
| 2 | 14,860 | 0.133 | 0.079 | 0.187 | 0.151 | 0.219 | 0.258 |
| 4 | 23,093 | 0.171 | 0.117 | 0.225 | 0.186 | 0.349 | 0.385 |
| 8 | 42,228 | 0.185 | 0.129 | 0.240 | 0.190 | 0.366 | 0.411 |
| 16 | 77,482 | 0.193 | 0.135 | 0.251 | 0.197 | 0.378 | 0.436 |
| **32** | **128,241** | **0.214** | **0.144** | **0.284** | **0.217** | **0.421** | **0.511** |

At 2 operations in flight, the distribution is extraordinarily tight: **p99 is 0.219 ms and p99.9 is 0.258 ms**,
barely above a 0.151 ms median. `put` is consistently about twice `get` at every level, which is the
synchronous replica hop and nothing else.

---

## Throughput profile
What latency would we get if our goal was throughput ...

Four client processes across *vm01*, *vm02* and *vm03*, with GridGain's default request pool.

| In flight | ops/s | mean ms| get ms | put ms | p50 | p99 | p99.9 |
|---|---:|---:|---:|---:|---:|---:|---:|
| 64 | 188,617 | 0.311 | 0.175 | 0.448 | 0.309 | 0.780 | 1.034 |
| **128** | **220,712** | **0.529** | **0.222** | **0.835** | **0.521** | **1.588** | **2.221** |
| 256 | 209,993 | 1.132 | 0.568 | 1.695 | — | — | — |
| 512 | 206,393 | 2.378 | 1.799 | 2.957 | — | — | — |

Past 128 operations in flight the cluster saturates: throughput falls while latency rises 4.5x.
Adding more client processes (8 instead of 4) returned *less* throughput, not more — which
establishes that ~220k was the server's limit rather than the load generator's, **with GridGain's
default settings**. The next section shows that limit is configurable.

> ⚠️ The 256 and 512 rows were measured before a generator JVM fix was applied, so their
> latencies are not strictly like-for-like with the rest of this table, and their percentiles were
> not reported. They sit past the performance knee anyway and therefore do not change the conclusion.

---

## Sizing the request pool — the single largest lever

GridGain sizes its thin-client request pool from the CPU count it sees: `max(8, availableProcessors)`,
so 64 threads per node here. Because a request holds one of those threads for its whole life, that
pool is the throughput ceiling. It is not normally exposed as a setting — a toolkit change was made
to reach it (`host_thread_pools.client_connector`).

Raising it from 64 to 256 per node, **with no change whatsoever to hardware or core count**:

| In flight | pool 64/node (default) | pool 256/node | pool 512/node |
|---|---:|---:|---:|
| 128 | 220,712 | 200,428 | — |
| 256 | 209,993 | 244,006 | — |
| 512 | 206,393 | **289,568** | 227,290 |
| 1024 | — | **304,789** | 297,787 |
| 2048 | — | — | 313,499 |

**Peak throughput went from 220,712 to 304,789 ops/s — up 38% — by changing one number.**

Two things are worth drawing out:

- **It is a tuning parameter with a peak, not a lever to turn up.** 512 per node is *worse* than 256
  at every comparable point, and uses *less* server CPU while delivering less throughput — the
  signature of thread thrashing rather than any GridGain limit. 256 per node was the optimum here;
  expect a different optimum on different hardware.
- **Bigger pools cost low-concurrency performance.** At 128 in flight the larger pool is 9% *slower*.
  The right size depends on where you intend to operate, which is why both profiles above are given.

---

## Why the CPU never looks busy

> GridGain sizes its thin-client request pool from the CPU count it sees: **one handler thread per
> CPU, per node**. Every request holds one of those threads for its entire life — including the time
> it spends doing nothing but waiting for the network round trip to the replica. The thread is
> *waiting*, not *computing*, so the CPU reads as idle while the slot is fully taken.
>
> The ceiling is therefore **handler threads ÷ time per request**. Since the pool defaults to the
> CPU count, the knee lands on **CPUs × nodes** until the pool is sized explicitly — which is what
> the previous section does.

In these tests, the CPUs were generally about 25% busy. This is an excellent finding. While we cannot increase the throughput with this unused resource, it is available to do in-situ computation - the secret sauce that makes GridGain powerful. Another way to look at it is that if we increased the server workload with distributed computing, we wouldn't immediately lower the throughput. We might see a slight increase in latency, but there is lots of room there to accept some workload.

That remains true at the higher throughput: even at 304,789 ops/s the servers sit at roughly 27% of
their logical CPUs.

This also means capping server CPUs *lowers* the ceiling rather than freeing capacity: halving them
took peak throughput from 219,388 to 168,265, while the capped servers used only 27% of the CPUs
they were still permitted. Note also that the scaling is **not** linear in CPU count — halving the
CPUs cost 23%, not 50%, and latency at the peak rose from 0.355 ms to 0.527 ms rather than holding
constant.

---

## What is not the bottleneck

All measured directly under load, not inferred:

| Resource | Observed | Headroom |
|---|---|---|
| Disk | 0 KB/s read and write | total — persistence off means no I/O at all |
| Network | 76 Mbps peak; 11–22 µs min RTT | 1 Gb link, 7.6% used |
| Server CPU | ~17 of 64 logical at peak | ~73% idle |
| Memory | 51 GB free, zero swap | ample |
| Page eviction | `PagesReplaceRate` 0 | no thrash |
| Server GC | mean 4.4 ms, 0 pauses over 50 ms | scavenge only, no global collections |

A read costs about 79 µs, of which roughly 20 µs is 'wire time'. The remaining ~75% is software on
both sides — protocol, thread handoffs, and the per-request chain itself.

---

## Cost of the options you can change

| Option | Effect | Notes |
|---|---:|---|
| Request pool 64 → 256 per node | **+38% throughput** | No hardware change. The largest single lever found. Has an optimum — 512 is worse than 256. |
| Persistence on | **+14% to +55% increased latency** | Worse the harder it is pushed; lands on writes; costs CPU as well as I/O. Region held at 32 GiB so only the write-ahead log varied. |
| Capping server CPUs | **−23% reduction in throughput** | Shrinks the request pool. The capped servers sat at 27% utilisation of what they were allowed. |
| Clients exceeding server vCPUs | **+29% increased throughput, then degrades** | Eventually context switching rears its ugly head and you get less throughput, not more |
| Generator JVM heap left unset | **p99.9 8x worse** | Not a GridGain effect: the load generator's own GC lands inside the latency it reports. Fixed heap required for any trustworthy tail measurement. |

---

## Not yet tested

- **A third data node.** The pool model predicts throughput scales with node count, which is the
  dimension that should scale cleanly — more pools, more memory, more network, with the replica hop
  unchanged. Per-node CPU scaling was measured and is sub-linear (see above); node scaling was not.
- **`PRIMARY_SYNC`.** `put` is consistently about twice `get`, which is the synchronous replica
  acknowledgement. Relaxing it would price that hop directly.
- **Intel comparison.** The harness is preserved and parameterised in `benchmark/` for exactly this.
  Note that the JVM differs (OpenJ9 here, HotSpot typically on x86) and is the control that matters
  most for a fair comparison.
