/*
 * netp.c -- network physical utilization, two backends.
 *
 *   netp_sysfs   /sys/class/net/<iface>/statistics/{rx,tx}_bytes (preferred)
 *   netp_procfs  /proc/net/dev (same data, less efficient parsing)
 *
 * Normalization: (rx+tx)/interval / nic_speed_bps * 100. NIC speed unknown
 * (link down or virtual iface) -> assume 1Gbps and mark DEGRADED.
 */

#include "backend.h"
#include "detect.h"
#include "procutil.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define DEFAULT_BPS (1000000000L / 8)

static struct {
    int                valid;
    char               iface[64];
    char               tx_path[256];
    char               rx_path[256];
    long               nic_speed_bps;
    int                assumed_speed;
    unsigned long long prev_tx;
    unsigned long long prev_rx;
} sf;

static const char *resolve_iface(void)
{
    const intp_target_t *t = intp_target_get();
    if (t && t->iface && t->iface[0]) return t->iface;
    return detect_default_iface();
}

long netp_resolve_speed(const char *iface, int *assumed_out)
{
    int  dummy = 0;
    int *assumed = assumed_out ? assumed_out : &dummy;
    const intp_target_t *t = intp_target_get();
    if (t && t->nic_speed_bps_override > 0) {
        *assumed = 0;
        return t->nic_speed_bps_override;
    }
    long bps = detect_nic_speed_bps(iface);
    if (bps <= 0) {
        *assumed = 1;
        return DEFAULT_BPS;
    }
    *assumed = 0;
    return bps;
}

static unsigned long long read_ull(const char *path)
{
    FILE *f = fopen(path, "r");
    if (!f) return 0;
    unsigned long long v = 0;
    if (fscanf(f, "%llu", &v) != 1) v = 0;
    fclose(f);
    return v;
}

static int sysfs_probe(void)
{
    const char *iface = resolve_iface();
    char p[256];
    snprintf(p, sizeof(p), "/sys/class/net/%.63s/statistics/tx_bytes", iface);
    FILE *f = fopen(p, "r");
    if (!f) return -1;
    fclose(f);
    return 0;
}

static int sysfs_init(void)
{
    const char *iface = resolve_iface();
    snprintf(sf.iface, sizeof(sf.iface), "%s", iface);
    snprintf(sf.tx_path, sizeof(sf.tx_path),
             "/sys/class/net/%.63s/statistics/tx_bytes", sf.iface);
    snprintf(sf.rx_path, sizeof(sf.rx_path),
             "/sys/class/net/%.63s/statistics/rx_bytes", sf.iface);
    sf.nic_speed_bps = netp_resolve_speed(sf.iface, &sf.assumed_speed);
    sf.prev_tx = read_ull(sf.tx_path);
    sf.prev_rx = read_ull(sf.rx_path);
    sf.valid   = 1;
    return 0;
}

static int sysfs_read(metric_sample_t *out, double interval_sec)
{
    if (!sf.valid || interval_sec <= 0) return -1;
    unsigned long long tx = read_ull(sf.tx_path);
    unsigned long long rx = read_ull(sf.rx_path);
    unsigned long long d  = (tx - sf.prev_tx) + (rx - sf.prev_rx);
    sf.prev_tx = tx;
    sf.prev_rx = rx;

    double bps = (double)d / interval_sec;
    double v   = bps / (double)sf.nic_speed_bps * 100.0;
    if (v < 0.0)  v = 0.0;
    if (v > 99.0) v = 99.0;

    out->value      = v;
    out->backend_id = "sysfs";
    if (sf.assumed_speed) {
        out->status = METRIC_STATUS_DEGRADED;
        out->note   = "assumed_1gbps";
    } else {
        out->status = METRIC_STATUS_OK;
        out->note   = NULL;
    }
    return 0;
}

static void sysfs_cleanup(void) { sf.valid = 0; }

/* ---- procfs fallback ---------------------------------------------------- */

static struct {
    int                valid;
    char               iface[64];
    long               nic_speed_bps;
    int                assumed_speed;
    unsigned long long prev_tx;
    unsigned long long prev_rx;
} pf;

static int procfs_probe(void)
{
    FILE *f = fopen("/proc/net/dev", "r");
    if (!f) return -1;
    fclose(f);
    return 0;
}

static int procfs_locate(unsigned long long *rx, unsigned long long *tx)
{
    netdev_entry_t entries[32];
    int n = procutil_read_netdev(entries, 32);
    if (n <= 0) return -1;
    for (int i = 0; i < n; i++) {
        if (strcmp(entries[i].iface, pf.iface) == 0) {
            *rx = entries[i].rx_bytes;
            *tx = entries[i].tx_bytes;
            return 0;
        }
    }
    return -1;
}

static int procfs_init(void)
{
    snprintf(pf.iface, sizeof(pf.iface), "%s", resolve_iface());
    pf.nic_speed_bps = netp_resolve_speed(pf.iface, &pf.assumed_speed);
    if (procfs_locate(&pf.prev_rx, &pf.prev_tx) != 0) return -1;
    pf.valid = 1;
    return 0;
}

static int procfs_read(metric_sample_t *out, double interval_sec)
{
    if (!pf.valid || interval_sec <= 0) return -1;
    unsigned long long rx = 0, tx = 0;
    if (procfs_locate(&rx, &tx) != 0) return -1;
    unsigned long long d = (tx - pf.prev_tx) + (rx - pf.prev_rx);
    pf.prev_tx = tx;
    pf.prev_rx = rx;

    double bps = (double)d / interval_sec;
    double v   = bps / (double)pf.nic_speed_bps * 100.0;
    if (v < 0.0)  v = 0.0;
    if (v > 99.0) v = 99.0;

    out->value      = v;
    out->backend_id = "procfs";
    out->status     = pf.assumed_speed ? METRIC_STATUS_DEGRADED
                                       : METRIC_STATUS_OK;
    out->note       = pf.assumed_speed ? "assumed_1gbps" : NULL;
    return 0;
}

static void procfs_cleanup(void) { pf.valid = 0; }

static backend_t b_sysfs = {
    .backend_id = "sysfs",
    .description = "/sys/class/net/<iface>/statistics/{rx,tx}_bytes",
    .probe = sysfs_probe, .init = sysfs_init,
    .read  = sysfs_read,  .cleanup = sysfs_cleanup,
};

static backend_t b_procfs = {
    .backend_id = "procfs",
    .description = "/proc/net/dev",
    .probe = procfs_probe, .init = procfs_init,
    .read  = procfs_read,  .cleanup = procfs_cleanup,
};

static metric_t m = {
    .metric_name = "netp",
    .backends    = { &b_sysfs, &b_procfs },
    .n_backends  = 2,
};

metric_t *metric_netp(void) { return &m; }
