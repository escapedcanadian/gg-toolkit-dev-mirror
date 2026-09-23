# GridGain 8 on IBM Power11

**Performance testing results and learnings.**

Analysis performed by David Brown (david.brown@mariadb.com)

21–22 September 2026 

PLatform - GridGain 8 v8.9.33 

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

In order to have a larger number of client threads than server threads in the provided environment, the servers were limited to 32 vCPUs (4 CPUs) and the remaining CPU resources on *vm01* and *vm02* were used for additional clients. For the purpose of clarity, the throughput numbers for these tests are scaled to represent servers with the same number of vCPUs as the other tests.

---

## Highlights
There is no single answer for 'how fast it is', but 'extermely' is the best summary.


Fastest read performance:  **0.079 ms**  at 29,720 ops/s 

Maximum recommended throughput:  **441,424 ops/s**,  128 clients at 0.529 ms mean

Target performance  **256,482 ops/s** while mean latency stays under **¼ ms** 

---

## Maximum throughput at each latency budget

This is the table to quote. Pick the latency a demo needs; read off what it can sustain.

| Mean latency budget | Sustained ops/s | Configuration |
|---|---:|---|
| ≤ 0.15 ms | 129,720| 4 concurrent clients |
| ≤ 0.20 ms | 154,964 | 32 concurrent clients |
| **≤ 0.25 ms** | **256,482** | **64 concurrent clients** |
| ≤ 0.35 ms | 377,234 | 128 concurrent clients |
| ≤ 0.55 ms | 441,424 | 256 concurrent clients |

The middle of that range is unusually cheap. Going from 8 to 32 operations in flight costs **12%
more read latency** and returns **three times the throughput**. The expensive ground is at the two
ends: the last 0.05 ms of latency costs 88% of throughput, and the last 70,000 ops/s costs a
doubling of latency.

---

## Low-latency profile
What throughput would we achieve if our goal were reliable, low latency ...

Percentiles from the generator's HdrHistogram over the same window the throughput is measured in.  Warm up period is excluded.

| In flight | ops/s | mean ms | get ms | put ms | p50 | p99 | p99.9 |
|---|---:|---:|---:|---:|---:|---:|---:|
| 4 | 29,720 | 0.133 | 0.079 | 0.187 | 0.151 | 0.219 | 0.258 |
| 8 | 46,186 | 0.171 | 0.117 | 0.225 | 0.186 | 0.349 | 0.385 |
| 16 | 84,456 | 0.185 | 0.129 | 0.240 | 0.190 | 0.366 | 0.411 |
| 32 | 154,964 | 0.193 | 0.135 | 0.251 | 0.197 | 0.378 | 0.436 |
| **64** | **256,482** | **0.214** | **0.144** | **0.284** | **0.217** | **0.421** | **0.511** |

At 4 concurrent clients, the distribution is extraordinarily tight: **p99 is 0.219 ms and p99.9 is 0.258 ms**,
barely above a 0.151 ms median. `put` is consistently about twice `get` at every level, which is the
synchronous replica hop and nothing else.

---

## Throughput profile
What latency would we get if our goal was throughput ...

| Clients | ops/s | mean ms| get ms | put ms | p50 | p99 | p99.9 |
|---|---:|---:|---:|---:|---:|---:|---:|
| 128 | 377,234| 0.311 | 0.175 | 0.448 | 0.309 | 0.780 | 1.034 |
| **256** | **441,424** | **0.529** | **0.222** | **0.835** | **0.521** | **1.588** | **2.221** |
| 512 | 419,986 | 1.132 | 0.568 | 1.695 | — | — | — |
| 1024 | 412,786 | 2.378 | 1.799 | 2.957 | — | — | — |

Past 256 concurrent clients the cluster is saturated: throughput falls while latency rises 4.5x. Increasing the number of concurrent clients beyond this point results in *less* throughput, not more, which is what establishes ~440k as GridGain's limit here rather than the load generator's.

> ⚠️ The 512 and 1024 rows were measured before a generator JVM fix was applied, so their
> latencies are not strictly like-for-like with the rest of this table, and their percentiles were
> not reported. They sit past the performance knee anyway and therefore do not change the conclusion.

---

## Why the CPU never looks busy

> GridGain sizes its thin-client request pool from the CPU count it sees: **one handler thread per
> CPU, per node**. Every request holds one of those threads for its entire life — including the time
> it spends doing nothing but waiting for the network round trip to the replica. The thread is
> *waiting*, not *computing*, so the CPU reads as idle while the slot is fully taken.
>
> The ceiling is therefore **handler threads ÷ time per request**, and handler threads is
> **CPUs × nodes**. You raise it by adding nodes, or by making each request shorter. Adding CPU is
> not available to you, because the limit was never CPU.

In these tests, the CPUs were generally about 25% busy. This is an excellent finding. While we cannot increase the throughput with this unused resource, it is available to do in-situ computation - the secret sauce that makes GridGain powerful. Another way to look at it is that if we increased the server workload with distributed computing, we wouldn't immediately lower the throughput. We might see a slight increase in latency, but there is lots of room there to accept some workload.

This also means capping server CPUs *lowers* the ceiling rather than freeing capacity: halving them
took peak throughput from 219,388 to 168,265, while the capped servers used only 27% of the CPUs
they were still permitted.

---

## What is not the bottleneck

All measured directly under load, not inferred:

| Resource | Observed | Headroom |
|---|---|---|
| Disk | 0 KB/s read and write | total — persistence off means no I/O at all |
| Network | 76 Mbps peak; 11–22 µs min RTT | 1 Gb link, 7.6% used |
| Server CPU | ~12 of 64 logical | ~80% idle |
| Memory | 51 GB free, zero swap | ample |
| Page eviction | `PagesReplaceRate` 0 | no thrash |
| Server GC | mean 4.4 ms, 0 pauses over 50 ms | scavenge only, no global collections |

A read costs about 79 µs, of which roughly 20 µs is 'wire time'. The remaining ~75% is software on
both sides — protocol, thread handoffs, and the per-request chain itself.

---

## Cost of the options you can change

| Option | Effect | Notes |
|---|---:|---|
| Persistence on | **+14% to +55% increased latency** | Worse the harder it is pushed; lands on writes; costs CPU as well as I/O. Region held at 32 GiB so only the write-ahead log varied. |
| Capping server CPUs | **−23% reduction in throughput** | Shrinks the request pool. The capped servers sat at 27% utilisation of what they were allowed. |
| Clients exceeding server vCPUs | **+29% increased throughput, then degrades** | Eventually context switching rears its ugly head and you get less throughput, not more |


