/*
 * intp_agg.bpf.c -- kernel-side programs for IntP V3.2.
 *
 * V3.2 is the in-kernel-aggregating variant of V3. Where V3 pushes one
 * record per event into a 16 MiB BPF_MAP_TYPE_RINGBUF and burns a
 * userspace consumer in a polling loop to drain it (see SBAC-PAD 2026
 * paper, section V-D: 188-390x context-switch amplification structurally
 * coupled to that consumer), V3.2 accumulates the same per-event signal
 * directly into per-CPU/per-PID counter maps. Userspace polls those
 * maps once per --interval and emits one TSV row -- no ring-buffer
 * draining, no `ring_buffer__poll`, no consumer-wakeup feedback loop.
 *
 * This commit (C02) defines the counter maps and shared helpers. Probes
 * land in C03 (netp), C05 (blk/cpu/llcmr), and C06 (nets via softirq).
 */

#include "vmlinux.h"
#include <bpf/bpf_helpers.h>

#include "intp_agg.bpf.h"

char LICENSE[] SEC("license") = "Dual MIT/GPL";

/* ------------------------------------------------------------------ Maps */

/* Config map: same shape as V3. Userspace populates this once at
 * attach time; probes read it on every invocation via intp_cfg(). */
struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, 1);
    __type(key, __u32);
    __type(value, struct intp_config);
} intp_cfg_map SEC(".maps");

/* Global counter map: one struct intp_counters per CPU at key=0. Each
 * probe does an __sync_fetch_and_add() into the current-CPU slot; the
 * userspace poller sums slots across all CPUs at sampling time. This is
 * the iprof pattern (Goege thesis ch. 3.3, Becker et al. UCC Companion
 * 2024) and what eliminates the ring-buffer consumer entirely. */
struct {
    __uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
    __uint(max_entries, 1);
    __type(key, __u32);
    __type(value, struct intp_counters);
} agg_global SEC(".maps");

/* Per-TGID counter map. Updated only when intp_cfg.system_wide == 0
 * (and the TGID passes the filter). Lets users break out a per-process
 * contribution via --per-pid-output. In system-wide mode we leave this
 * empty -- agg_global already covers everything on the box. */
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, INTP_AGG_HASH_MAX);
    __type(key, __u32);
    __type(value, struct intp_counters);
} agg_per_pid SEC(".maps");

/* Single-slot per-CPU template of zeros, used to seed new entries in
 * agg_per_pid without putting a struct intp_counters on the BPF stack
 * (the struct is 128 bytes; the verifier accepts it, but pushing it
 * through every probe inflates instruction count). Userspace doesn't
 * touch this; the BPF side reads from it under BPF_NOEXIST insertion. */
struct {
    __uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
    __uint(max_entries, 1);
    __type(key, __u32);
    __type(value, struct intp_counters);
} agg_zero SEC(".maps");

/* Dynamically-tracked TGIDs of processes descended from any of the
 * configured target PIDs. Populated from two places:
 *
 *   1. Userspace seeds it at attach time by walking /proc to enumerate
 *      pre-existing descendants. Workloads like stress-ng spawn their
 *      stressor children before the profiler attaches; without the seed
 *      those children are invisible to the PID filter even though their
 *      parent is in target_pids.
 *
 *   2. The sched_process_fork tracepoint adds child TGIDs whenever a
 *      task already in the filter (config or this map) forks. New forks
 *      after attach therefore stay tracked without requiring polling.
 *
 * sched_process_exit removes thread-leader TGIDs on process exit so the
 * map doesn't grow unbounded. value is just a presence flag. Same map
 * as V3 -- the filter machinery is unchanged in V3.2. */
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 8192);
    __type(key, __u32);
    __type(value, __u8);
} descendant_tgids SEC(".maps");

/* -------------------------------------------------------------- Helpers */

static __always_inline struct intp_config *intp_cfg(void)
{
    __u32 key = 0;
    return bpf_map_lookup_elem(&intp_cfg_map, &key);
}

static __always_inline int is_system_wide(void)
{
    struct intp_config *cfg = intp_cfg();
    return !cfg || cfg->system_wide;
}

/* Returns 1 if pid is to be observed under the current config.
 *
 * Lookup order: (a) system_wide short-circuit, (b) static target_pids
 * array from the config map, (c) dynamic descendant_tgids hash map.
 * Same logic as V3. */
static __always_inline int pid_in_filter(struct intp_config *cfg, __u32 pid)
{
    if (!cfg)              return 1;
    if (cfg->system_wide)  return 1;

    __u32 n = cfg->num_target_pids;
    if (n > INTP_MAX_PIDS) n = INTP_MAX_PIDS;

    for (__u32 i = 0; i < INTP_MAX_PIDS; i++) {
        if (i >= n) break;
        if (cfg->target_pids[i] == pid) return 1;
    }

    __u8 *p = bpf_map_lookup_elem(&descendant_tgids, &pid);
    if (p) return 1;
    return 0;
}

/* Short-circuit form using the current task's TGID. */
static __always_inline int should_monitor_current(void)
{
    struct intp_config *cfg = intp_cfg();
    __u32 pid = bpf_get_current_pid_tgid() >> 32;
    return pid_in_filter(cfg, pid);
}

/* Return the per-CPU agg_global slot for the calling probe. NULL on
 * lookup failure (which is unreachable for PERCPU_ARRAY[key=0] in
 * practice, but the verifier insists). */
static __always_inline struct intp_counters *agg_global_slot(void)
{
    __u32 key = 0;
    return bpf_map_lookup_elem(&agg_global, &key);
}

/* Return (and lazily create) the per-TGID slot. The lazy-create path
 * seeds from agg_zero rather than putting a 128-byte struct on the
 * probe stack. The BPF_NOEXIST insert can race across CPUs; the
 * subsequent lookup is authoritative. */
static __always_inline struct intp_counters *
agg_per_pid_slot(__u32 tgid)
{
    struct intp_counters *p = bpf_map_lookup_elem(&agg_per_pid, &tgid);
    if (p) return p;

    __u32 zk = 0;
    struct intp_counters *z = bpf_map_lookup_elem(&agg_zero, &zk);
    if (!z) return NULL;

    bpf_map_update_elem(&agg_per_pid, &tgid, z, BPF_NOEXIST);
    return bpf_map_lookup_elem(&agg_per_pid, &tgid);
}
