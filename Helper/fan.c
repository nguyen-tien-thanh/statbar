/*
 * statbar-fan: tiny root helper that holds a fan mode while StatBar is running.
 * usage: statbar-fan <owner-pid> <mode-file>
 * mode-file contains: auto | cool | max
 * Restores automatic fan control and exits when the owner process exits
 * or the mode becomes "auto".
 */
#include "../Bridge/smc.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <errno.h>
#include <unistd.h>
#include <sys/stat.h>

static int g_fans = 0;
static volatile sig_atomic_t g_stop = 0;
static void on_sig(int s) { (void)s; g_stop = 1; }

static void restore_auto(void) {
    char k[5];
    for (int i = 0; i < g_fans; i++) { snprintf(k, sizeof k, "F%dMd", i); smc_write_u8(k, 0); }
    smc_write_u8("Ftst", 0);
}

static double cpu_temp_max(void) {
    /* highest Apple Silicon CPU die sensor among a few common keys */
    const char *keys[] = {"Tp01","Tp05","Tp09","Tp0D","Tp0b","Tp0f","Tp0V","Tp0Z","Te05","Te09","TC0P", 0};
    double m = 0, v;
    for (int i = 0; keys[i]; i++) if (smc_read_double(keys[i], &v) == 0 && v > m && v < 130) m = v;
    return m;
}

static void apply(double pct) {
    char k[5]; double mn, mx;
    smc_write_u8("Ftst", 1); /* unlock on Apple Silicon; harmless if absent */
    for (int i = 0; i < g_fans; i++) {
        snprintf(k, sizeof k, "F%dMn", i); if (smc_read_double(k, &mn) != 0) mn = 1000;
        snprintf(k, sizeof k, "F%dMx", i); if (smc_read_double(k, &mx) != 0) mx = 6000;
        snprintf(k, sizeof k, "F%dMd", i); smc_write_u8(k, 1);
        snprintf(k, sizeof k, "F%dTg", i); smc_write_float(k, (float)(mn + (mx - mn) * pct));
    }
}

int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "usage: %s <pid> <mode-file>\n", argv[0]); return 1; }
    pid_t owner = (pid_t)atoi(argv[1]);
    const char *modefile = argv[2];
    if (smc_open() != 0) return 2;
    double n; g_fans = smc_read_double("FNum", &n) == 0 ? (int)n : 0;
    if (g_fans <= 0) return 3;

    char pidfile[1024]; snprintf(pidfile, sizeof pidfile, "%s.pid", modefile);
    FILE *pf = fopen(pidfile, "w"); if (pf) { fprintf(pf, "%d\n", getpid()); fclose(pf); chmod(pidfile, 0644); }

    signal(SIGTERM, on_sig); signal(SIGINT, on_sig); signal(SIGHUP, on_sig);
    while (!g_stop) {
        if (kill(owner, 0) != 0 && errno == ESRCH) break;
        char mode[32] = "auto";
        FILE *f = fopen(modefile, "r");
        if (f) { if (!fgets(mode, sizeof mode, f)) strcpy(mode, "auto"); fclose(f); }
        if (strncmp(mode, "max", 3) == 0) apply(1.0);
        else if (strncmp(mode, "cool", 4) == 0) apply(cpu_temp_max() > 90 ? 1.0 : 0.7); /* safety: go max when hot */
        else break;
        sleep(2);
    }
    restore_auto();
    unlink(pidfile);
    smc_close();
    return 0;
}
