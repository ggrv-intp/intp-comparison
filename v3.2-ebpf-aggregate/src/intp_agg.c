/*
 * intp_agg.c -- userspace main for IntP V3.2.
 *
 * V3.2 polls per-CPU/per-PID counter maps once per --interval instead of
 * draining a ring buffer in a tight loop. This file is the C01 scaffold:
 * argv parsing + capability detection are wired up so the binary builds
 * end-to-end and `--list-capabilities` works, but the BPF skeleton is
 * still empty (no probes) and the polling loop / per-CPU snapshot diff
 * land in C04.
 */

#include <bpf/bpf.h>
#include <bpf/libbpf.h>
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "intp_agg.bpf.h"
#include "intp_agg.skel.h"
#include "intp_agg_args.h"

#include "../detect/detect.h"

static volatile sig_atomic_t g_running = 1;
static void on_signal(int sig) { (void)sig; g_running = 0; }

static int libbpf_quiet(enum libbpf_print_level lvl, const char *fmt, va_list ap)
{
    if (lvl == LIBBPF_WARN) return vfprintf(stderr, fmt, ap);
    return 0;
}

int main(int argc, char **argv)
{
    intp_args_t args;
    int r = intp_args_parse(argc, argv, &args);
    if (r == 1) return 0;
    if (r < 0)  return 1;

    system_capabilities_t caps;
    detect_all(&caps);

    if (args.nic_speed_bps_override > 0)
        caps.nic_speed_bps = args.nic_speed_bps_override;
    if (args.mem_bw_max_bps_override > 0)
        caps.mem_bw_max_bps = args.mem_bw_max_bps_override;
    if (args.llc_size_bytes_override > 0)
        caps.llc_size_bytes = args.llc_size_bytes_override;

    if (args.list_capabilities) {
        print_capabilities(&caps, stdout);
        return 0;
    }

    if (!args.verbose) libbpf_set_print(libbpf_quiet);

    signal(SIGINT,  on_signal);
    signal(SIGTERM, on_signal);

    /* C01 scaffold: open + load the (currently empty) skeleton, sleep
     * one interval, exit. This validates the build pipeline end-to-end:
     * vmlinux.h dump, BPF object compile, skeleton gen, user link.
     * The probes, counter maps, and polling loop arrive in C02-C07. */
    struct intp_agg_bpf *skel = intp_agg_bpf__open();
    if (!skel) {
        fprintf(stderr, "failed to open BPF skeleton: %s\n", strerror(errno));
        return 1;
    }

    if (intp_agg_bpf__load(skel)) {
        fprintf(stderr, "failed to load BPF: %s\n", strerror(errno));
        intp_agg_bpf__destroy(skel);
        return 1;
    }

    fprintf(stderr,
            "info: V3.2 scaffold loaded (no probes attached yet); "
            "sleeping %.2fs then exiting.\n",
            args.interval_sec);
    sleep((unsigned int)args.interval_sec);

    intp_agg_bpf__destroy(skel);
    return 0;
}
