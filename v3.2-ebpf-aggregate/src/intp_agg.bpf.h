/*
 * intp_agg.bpf.h -- types shared between the BPF-side programs
 * (intp_agg.bpf.c) and the userspace loader (intp_agg.c) for V3.2.
 *
 * Stub for C01 scaffold. Real types land in C02.
 *
 * On the BPF side, __u32/__u64 come from vmlinux.h which the translation
 * unit has already included before this header. Userspace TUs get them
 * from <linux/types.h> instead; we pull that in here under the guard
 * below so callers don't have to remember.
 */

#ifndef INTP_AGG_BPF_H
#define INTP_AGG_BPF_H

#ifndef __VMLINUX_H__
#include <linux/types.h>
#endif

/* Kept small so the in-kernel PID filter loop stays under the 5.8 verifier's
 * instruction budget on the first pass. Same value as V3. */
#define INTP_MAX_PIDS        64

/* Config map: userspace pushes one record into the single-entry array
 * before attaching programs. Same struct as V3 -- only the consumer side
 * differs in V3.2. */
struct intp_config {
    __u32 target_pids[INTP_MAX_PIDS];
    __u32 num_target_pids;
    __u8  system_wide;
    __u8  _pad0;
    __u16 _pad1;
};

#endif /* INTP_AGG_BPF_H */
