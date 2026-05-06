# v1.1 -- SystemTap with userspace helper for hardware metrics

Status: design phase. Implementation pending.

## Why a helper

Both v0 (legacy `v1-original`) and the lineage that is now v1 (legacy
`v3-updated-resctrl`) tried to read uncore IMC counters and resctrl files
from SystemTap embedded C in probe context. On kernel >= 5.15 this triggers
"voluntary context switch within RCU read-side critical section" (see
`bench/findings/v3-modernization-reliability-findings.md`)
because `perf_event_create_kernel_counter`, `mutex_lock`, `kmalloc(GFP_KERNEL)`,
`filp_open`, `kernel_write` and `kernel_read` can sleep, and probes hold an
RCU read lock. The system hangs hard and only power-cycle recovers.

v1 (the restored stap-only build) avoids all of these calls; it reports
mbw=0 and llcocc=0 because those metrics need exactly those operations.

v1.1 reintroduces mbw and llcocc by moving every RCU-unsafe operation out
of the kernel module and into a separate userspace process (`intp-helper`)
that owns:

- the uncore IMC perf events (opened via `perf_event_open(2)`)
- the resctrl `mon_group` and its `tasks` file
- the periodic read/aggregate cycle

The helper writes the current values to a single file. The stap script
reads that file from a procfs probe -- the only place where embedded C
file I/O is RCU-safe (a procfs read by definition runs in user-task
context, no RCU read lock held).

## Architecture

```
+------------------------------+        +---------------------------------+
| intp-v1.1.stp                |        | intp-helper (userspace daemon)  |
| (kernel module, RCU-bound)   |        | (process context, may sleep)    |
|                              |        |                                 |
|  - software metrics:         |        |  - opens uncore IMC events via  |
|     net, block, cpu, llcmr   |        |    perf_event_open(2)           |
|     (same as v1)             |        |  - mounts /sys/fs/resctrl,      |
|                              |        |    creates mon_groups/intp/     |
|  - reads /tmp/intp-hw-data   |        |  - polls /proc for PIDs whose   |
|    via embedded C kernel_read|<-----+ |    comm matches the pattern,    |
|    in procfs("intestbench")  |      | |    writes them to mon_group's   |
|    .read probe (safe ctx)    |      | |    tasks file                   |
|                              |      | |  - every 1s: reads counters,    |
+------------------------------+      | |    aggregates, atomically       |
                                      +-+    rewrites /tmp/intp-hw-data   |
                                        |                                 |
                                        +---------------------------------+
```

No stap -> helper IPC. The two processes share *only* the workload pattern
(passed to both as a CLI argument) and the data file (helper writes,
stap reads).

## Responsibilities of the helper

### 1. Uncore IMC (memory bandwidth)

For each IMC channel exposed as a uncore PMU type (e.g. on Sapphire
Rapids: types 78..89 with configs 0x0304 = `UNC_M_CAS_COUNT.RD` and
0x0c04 = `UNC_M_CAS_COUNT.WR`), the helper:

1. opens a counting-mode perf event via `perf_event_open(2)` with
   `cpu = first_cpu_in_socket`, `pid = -1`, `flags = PERF_FLAG_FD_CLOEXEC`
2. enables it and reads its 64-bit counter at the polling tick
3. computes bytes = (sum of CAS counts) * 64 (cache-line size)
4. converts to bandwidth (bytes / interval_seconds) and to a percentage
   of the platform's nominal DRAM bandwidth (parameter, default 281600
   MB/s for Xeon Gold 5412U with 8x DDR5-4800)
5. writes the percentage as the `mbw` field of the data file

The helper never opens uncore events from inside a probe; it does so
once at startup, in process context, with full GFP_KERNEL freedom. This
is the key safety property.

### 2. resctrl mon_group (LLC occupancy)

At startup:

1. ensure resctrl is mounted at `/sys/fs/resctrl`; if not, attempt mount;
   if that fails, run with llcocc disabled (write 0)
2. create `/sys/fs/resctrl/mon_groups/intp/` (or reuse if exists)

Per polling tick (default 1s):

1. enumerate PIDs whose `/proc/<pid>/comm` matches the workload pattern
2. compute the diff against the previous tick's set
3. write each new PID to `mon_groups/intp/tasks` (`echo <pid> > tasks`)
4. PIDs that have died are removed automatically by the kernel
5. read every `mon_data/mon_L3_*/llc_occupancy`, sum, normalize against
   the platform's L3 size (parameter, default 46080 KB)
6. write the percentage as the `llcocc` field of the data file

At shutdown: remove the mon_group with `rmdir`.

### 3. Data file

Single file, single line, atomic update via tmpfile+rename:

```
/tmp/intp-hw-data
---
<timestamp_ns>\t<mbw_pct>\t<llcocc_pct>\n
```

Writes are tmpfile-then-rename so a partial write is never observed.

The stap side reads the line, parses three integers, uses the second and
third as `mbw` and `llcocc`. If the file is missing or older than 5s,
both fields are 0 (graceful degradation if the helper crashed).

The format is intentionally minimal -- one line, three integers --
because the kernel-side reader uses `kernel_read` on a fixed buffer in
embedded C and we want the parsing logic trivial.

## Lifecycle

```
   (workload pattern $1, e.g. "stress-ng")

   t-1s:  intp-helper $1 &              # start helper first
   t=0:   stap intp-v1.1.stp $1 ...     # then stap

   ... workload runs, helper writes hw-data, stap reads it ...

   t=N:   stap exits (workload ended)
   t=N+1: kill -TERM $intp_helper_pid
                                        # helper handles SIGTERM:
                                        #   close perf events
                                        #   rmdir mon_groups/intp
                                        #   delete /tmp/intp-hw-data
```

The bench script (`bench/run-intp-bench.sh`) launches the helper before
stap and tears it down after, in a single bracketed lifecycle.

## Why this is safe

| RCU-unsafe operation | Where it ran in legacy v3 (now removed) | Where it runs in v1.1 |
|----------------------|--------------------|-----------------------|
| `perf_event_create_kernel_counter` (sleeps in `mutex_lock`) | stap embedded C from `probe begin` | helper, in main(), once |
| `filp_open` + `kernel_write` to `mon_groups/intp/tasks` | stap embedded C from `process(@1).begin` | helper, in poll loop, in main() |
| `filp_open` + `kernel_read` of `llc_occupancy` | stap embedded C from procfs read probe (this one was safe; kept in v1.1 as `kernel_read` of `/tmp/intp-hw-data`) | helper reads `llc_occupancy` itself; stap only reads `/tmp/intp-hw-data` from procfs probe |

procfs read probes run in user-task context (the user is running
`cat /proc/systemtap/.../intestbench`); embedded C `kernel_read` of a
small file in `/tmp` from there is the supported pattern for stap-side
data ingest and matches what legacy v3 did for occupancy (the only place
the legacy v3 build got right). v1.1 keeps that pattern and removes the rest.

## Open questions for review

1. **Polling interval**: 1s matches the existing `timer.s(1)` in stap.
   Higher rate would give better mbw resolution but more poll overhead.
2. **Pattern matching**: `comm` (15-char limit) or full `cmdline`? `comm`
   is faster but "stress-ng" workloads spawn child processes with the
   same comm so it works. `cmdline` is more flexible.
3. **Multiple workloads**: pattern is currently a single string. For
   pairwise/cross-workload campaigns we may want multiple patterns or
   a regex. For now, single pattern with substring match.
4. **Fallback behavior**: if RDT is not available on the host, the
   helper should report mbw and llcocc = 0 and *not* fail to start;
   stap-side stays the same. Detected via `/proc/cpuinfo` flags.
5. **Concurrent helpers**: only one `mon_groups/intp/` exists. Two
   parallel campaigns would clash. Use a unique name (PID-suffixed) per
   helper instance, or reject startup if directory already exists.

## Implementation language

C (no external deps beyond glibc + libpthread + libc syscall wrappers
for `perf_event_open`). Builds with `gcc -O2`. ~300-500 lines including
arg parsing and clean shutdown.

Why not bash: floating-point conversion for bandwidth, atomic file
rewrite, perf_event_open syscall handling -- all brittle in shell.

Why not Python: extra runtime dependency on a host that may not have it
ready, slower polling startup, larger memory footprint than necessary
for a 1Hz-loop daemon.

## Comparison vs v3.1 (bpftrace) helper script

v3.1 uses a userspace orchestrator written in Python. v1.1's helper is
similar in spirit but written in C and serves a different consumer
(SystemTap kernel module, via file IPC).

The two helpers do not share code today. If both stabilize, we may
extract a small "intp-rdt" library, but that is out of scope for the
initial v1.1 implementation.
