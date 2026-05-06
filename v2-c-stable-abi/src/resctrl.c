/*
 * resctrl.c -- monitoring group lifecycle and counter aggregation.
 *
 * Every backend that uses resctrl (mbw, llcocc) goes through this module.
 * Multi-domain summing matters: modern Xeon SP and EPYC expose one
 * mon_L3_NN per L3 cache instance (per socket on Xeon, per CCX on EPYC).
 */

#include "resctrl.h"

#include <dirent.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <unistd.h>

#define RESCTRL_ROOT "/sys/fs/resctrl"

static int dir_exists(const char *p)
{
    struct stat s;
    return stat(p, &s) == 0 && S_ISDIR(s.st_mode);
}

int resctrl_ensure_mounted(void)
{
    if (dir_exists(RESCTRL_ROOT "/info") ||
        dir_exists(RESCTRL_ROOT "/mon_groups"))
        return 0;
    if (!dir_exists(RESCTRL_ROOT))
        return -1;
    if (geteuid() != 0)
        return -1;
    if (mount("resctrl", RESCTRL_ROOT, "resctrl", 0, NULL) == 0)
        return 0;
    return -1;
}

static void group_dir(const char *name, char *out, size_t outsz)
{
    snprintf(out, outsz, "%s/mon_groups/%s", RESCTRL_ROOT, name);
}

int resctrl_create_mongroup(const char *name)
{
    if (!name || !*name) return -1;
    if (resctrl_ensure_mounted() != 0) return -1;

    char dir[RESCTRL_PATH_MAX];
    group_dir(name, dir, sizeof(dir));
    if (mkdir(dir, 0755) == 0) return 0;
    if (errno == EEXIST) return 0;
    return -1;
}

int resctrl_assign_pids(const char *name,
                        const pid_t *pids,
                        size_t n_pids)
{
    if (!name || !pids || n_pids == 0) return -1;

    char tasks[RESCTRL_PATH_MAX];
    snprintf(tasks, sizeof(tasks),
             "%s/mon_groups/%s/tasks", RESCTRL_ROOT, name);

    int  accepted = 0;
    for (size_t i = 0; i < n_pids; i++) {
        FILE *f = fopen(tasks, "w");
        if (!f) return -1;
        if (fprintf(f, "%d\n", (int)pids[i]) > 0)
            accepted++;
        fclose(f);
    }
    return accepted > 0 ? 0 : -1;
}

int resctrl_enumerate_domains(const char *name,
                              const char *filename,
                              char paths[][RESCTRL_PATH_MAX],
                              int max_domains)
{
    char base[RESCTRL_PATH_MAX];
    snprintf(base, sizeof(base),
             "%s/mon_groups/%s/mon_data", RESCTRL_ROOT, name);

    DIR *d = opendir(base);
    if (!d) return 0;

    int n = 0;
    struct dirent *e;
    while ((e = readdir(d)) != NULL && n < max_domains) {
        if (strncmp(e->d_name, "mon_L3_", 7) != 0) continue;
        char p[RESCTRL_PATH_MAX];
        snprintf(p, sizeof(p), "%.200s/%.32s/%.64s",
                 base, e->d_name, filename);
        struct stat st;
        if (stat(p, &st) != 0) continue;
        snprintf(paths[n], RESCTRL_PATH_MAX, "%s", p);
        n++;
    }
    closedir(d);
    return n;
}

long resctrl_sum_paths(char paths[][RESCTRL_PATH_MAX], int n_paths)
{
    unsigned long long sum = 0;
    int seen = 0;
    for (int i = 0; i < n_paths; i++) {
        FILE *f = fopen(paths[i], "r");
        if (!f) continue;
        unsigned long long v = 0;
        if (fscanf(f, "%llu", &v) == 1) {
            sum += v;
            seen = 1;
        }
        fclose(f);
    }
    return seen ? (long)sum : -1;
}

static long sum_counter(const char *name, const char *file)
{
    char paths[RESCTRL_MAX_DOMAINS][RESCTRL_PATH_MAX];
    int  n = resctrl_enumerate_domains(name, file, paths, RESCTRL_MAX_DOMAINS);
    if (n == 0) return -1;
    return resctrl_sum_paths(paths, n);
}

long resctrl_read_llc_occupancy(const char *name)
{
    return sum_counter(name, "llc_occupancy");
}

long resctrl_read_mbm_total(const char *name)
{
    return sum_counter(name, "mbm_total_bytes");
}

long resctrl_read_mbm_local(const char *name)
{
    return sum_counter(name, "mbm_local_bytes");
}

int resctrl_remove_mongroup(const char *name)
{
    char dir[RESCTRL_PATH_MAX];
    group_dir(name, dir, sizeof(dir));
    if (rmdir(dir) == 0) return 0;
    if (errno == ENOENT) return 0;
    return -1;
}

int resctrl_max_rmids(void)
{
    FILE *f = fopen(RESCTRL_ROOT "/info/L3_MON/num_rmids", "r");
    if (!f) return -1;
    long v = 0;
    int n = fscanf(f, "%ld", &v);
    fclose(f);
    return n == 1 ? (int)v : -1;
}

int resctrl_rmids_in_use(void)
{
    DIR *d = opendir(RESCTRL_ROOT "/mon_groups");
    if (!d) return -1;
    int count = 0;
    struct dirent *e;
    while ((e = readdir(d)) != NULL) {
        if (e->d_name[0] == '.') continue;
        count++;
    }
    closedir(d);
    return count;
}
