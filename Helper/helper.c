/*
 * statbar-helper: the only code StatBar runs as root.
 *
 *   statbar-helper fan auto
 *   statbar-helper fan cool|max <owner-pid>   (daemonizes, holds the mode until owner exits or mode changes)
 *   statbar-helper purge
 *   statbar-helper flushdns
 *   statbar-helper reindex                    (rebuild Spotlight index)
 *   statbar-helper trash-app /Applications/X.app [uid]
 *       moves a third-party app bundle into the invoking user's Trash (recoverable)
 *
 * No user-supplied paths are accepted. The fan daemon's pid lives in a root-only location.
 */
#include "../Bridge/smc.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <spawn.h>
#include <libproc.h>
#include <sys/wait.h>
#include <sys/stat.h>
#include <limits.h>
#include <pwd.h>
#include <time.h>
#include <fts.h>
#include <CoreFoundation/CoreFoundation.h>

#define PIDFILE "/var/run/statbar-fan.pid"

static int g_fans = 0;
static volatile sig_atomic_t g_stop = 0;
static void on_sig(int s) { (void)s; g_stop = 1; }

static int run(const char *path, char *const argv[]) {
    pid_t pid; int st = 0;
    char *const env[] = { "PATH=/usr/bin:/bin:/usr/sbin:/sbin", NULL };
    if (posix_spawn(&pid, path, NULL, NULL, argv, env) != 0) return -1;
    if (waitpid(pid, &st, 0) < 0) return -1;
    return WIFEXITED(st) ? WEXITSTATUS(st) : -1;
}

static int fan_count(void) { double n = 0; return smc_read_double("FNum", &n) == 0 ? (int)n : 0; }

static void restore_auto(void) {
    char k[5];
    for (int i = 0; i < g_fans; i++) { snprintf(k, sizeof k, "F%dMd", i); smc_write_u8(k, 0); }
    smc_write_u8("Ftst", 0);
}

static double cpu_temp_max(void) {
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

/* Stop a previously started fan daemon – only if that pid really is this same helper binary. */
static void stop_existing(void) {
    FILE *f = fopen(PIDFILE, "r");
    if (!f) return;
    int p = 0; if (fscanf(f, "%d", &p) != 1) p = 0;
    fclose(f);
    if (p <= 1 || p == getpid()) return;
    char mine[PROC_PIDPATHINFO_MAXSIZE] = {0}, theirs[PROC_PIDPATHINFO_MAXSIZE] = {0};
    if (proc_pidpath(getpid(), mine, sizeof mine) <= 0 || proc_pidpath(p, theirs, sizeof theirs) <= 0 ||
        strcmp(mine, theirs) != 0) { unlink(PIDFILE); return; }
    kill(p, SIGTERM);
    for (int i = 0; i < 50 && kill(p, 0) == 0; i++) usleep(100000);
}

static int fan(const char *mode, pid_t owner) {
    if (smc_open() != 0) return 2;
    g_fans = fan_count();
    if (g_fans <= 0) return 3;
    stop_existing();
    if (strcmp(mode, "auto") == 0) { restore_auto(); return 0; }

    double pct;
    if (strcmp(mode, "max") == 0) pct = 1.0;
    else if (strcmp(mode, "cool") == 0) pct = 0.7;
    else return 1;
    if (owner <= 1 || kill(owner, 0) != 0) return 1;

    pid_t child = fork();
    if (child < 0) return 4;
    if (child > 0) return 0;          /* parent returns immediately */

    setsid();
    int dn = open("/dev/null", O_RDWR);
    if (dn >= 0) { dup2(dn, 0); dup2(dn, 1); dup2(dn, 2); if (dn > 2) close(dn); }
    int fd = open(PIDFILE, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, 0644);
    if (fd >= 0) { dprintf(fd, "%d\n", getpid()); close(fd); }

    signal(SIGTERM, on_sig); signal(SIGINT, on_sig); signal(SIGHUP, on_sig);
    while (!g_stop) {
        if (kill(owner, 0) != 0 && errno == ESRCH) break;
        apply(pct >= 1.0 || cpu_temp_max() > 90 ? 1.0 : pct);   /* safety: go max when hot */
        for (int i = 0; i < 20 && !g_stop; i++) usleep(100000);
    }
    restore_auto();
    unlink(PIDFILE);
    smc_close();
    _exit(0);
}

static void chown_tree(const char *path, uid_t uid, gid_t gid) {
    char *argv[] = { (char *)path, NULL };
    FTS *fts = fts_open(argv, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, NULL);
    if (!fts) return;
    FTSENT *e;
    while ((e = fts_read(fts))) {
        if (e->fts_info == FTS_DP) continue;
        lchown(e->fts_accpath, uid, gid);
    }
    fts_close(fts);
}

/* Only third-party .app bundles directly in /Applications (or one folder deep). */
static int trash_app(const char *arg, const char *uid_arg) {
    struct stat st;
    if (lstat(arg, &st) != 0 || S_ISLNK(st.st_mode) || !S_ISDIR(st.st_mode)) return 10;
    char real[PATH_MAX];
    if (!realpath(arg, real)) return 11;
    const char *prefix = "/Applications/";
    size_t pl = strlen(prefix), rl = strlen(real);
    if (strncmp(real, prefix, pl) != 0 || rl < pl + 5 || strcmp(real + rl - 4, ".app") != 0) return 12;
    int slashes = 0;
    for (const char *c = real + pl; *c; c++) if (*c == '/') slashes++;
    if (slashes > 1) return 13;

    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)real, (CFIndex)rl, true);
    CFBundleRef b = url ? CFBundleCreate(NULL, url) : NULL;
    CFStringRef bid = b ? CFBundleGetIdentifier(b) : NULL;
    int apple = !bid || CFStringHasPrefix(bid, CFSTR("com.apple."));
    if (b) CFRelease(b);
    if (url) CFRelease(url);
    if (apple) return 14;

    const char *su = getenv("SUDO_UID");
    uid_t uid = (uid_t)strtol(su ? su : (uid_arg ? uid_arg : "0"), NULL, 10);
    struct passwd *pw = getpwuid(uid);
    if (uid == 0 || !pw) return 15;

    char dest[PATH_MAX];
    const char *base = strrchr(real, '/') + 1;
    snprintf(dest, sizeof dest, "%s/.Trash/%s", pw->pw_dir, base);
    if (access(dest, F_OK) == 0) {
        char stamp[32]; time_t t = time(NULL); strftime(stamp, sizeof stamp, "%H.%M.%S", localtime(&t));
        snprintf(dest, sizeof dest, "%s/.Trash/%.*s %s.app", pw->pw_dir, (int)(strlen(base) - 4), base, stamp);
    }
    if (rename(real, dest) != 0) return 16;
    chown_tree(dest, uid, pw->pw_gid);
    return 0;
}

int main(int argc, char **argv) {
    if (argc >= 2 && strcmp(argv[1], "reindex") == 0) {
        char *const a[] = { "mdutil", "-E", "/", NULL };
        return run("/usr/bin/mdutil", a) == 0 ? 0 : 1;
    }
    if (argc >= 3 && strcmp(argv[1], "trash-app") == 0) {
        return trash_app(argv[2], argc >= 4 ? argv[3] : NULL);
    }
    if (argc >= 2 && strcmp(argv[1], "purge") == 0) {
        char *const a[] = { "purge", NULL };
        return run("/usr/sbin/purge", a) == 0 ? 0 : 1;
    }
    if (argc >= 2 && strcmp(argv[1], "flushdns") == 0) {
        char *const a[] = { "dscacheutil", "-flushcache", NULL };
        char *const b[] = { "killall", "-HUP", "mDNSResponder", NULL };
        int r1 = run("/usr/bin/dscacheutil", a), r2 = run("/usr/bin/killall", b);
        return (r1 == 0 && r2 == 0) ? 0 : 1;
    }
    if (argc >= 3 && strcmp(argv[1], "fan") == 0) {
        pid_t owner = argc >= 4 ? (pid_t)strtol(argv[3], NULL, 10) : 0;
        return fan(argv[2], owner);
    }
    fprintf(stderr, "usage: statbar-helper fan auto|cool|max [owner-pid] | purge | flushdns | reindex | trash-app <path> [uid]\n");
    return 64;
}
