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
 * This file (C01 scaffold) carries no probes yet -- just the license
 * symbol and the config map declaration so the skeleton generates and
 * loads as an empty BPF object. Probes and counter maps land in C02+.
 */

#include "vmlinux.h"
#include <bpf/bpf_helpers.h>

#include "intp_agg.bpf.h"

char LICENSE[] SEC("license") = "Dual MIT/GPL";

/* Config map: same shape as V3. Userspace populates this once at
 * attach time; probes read it on every invocation via intp_cfg(). */
struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, 1);
    __type(key, __u32);
    __type(value, struct intp_config);
} intp_cfg_map SEC(".maps");
