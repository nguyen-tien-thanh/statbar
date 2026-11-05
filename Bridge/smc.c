#include "smc.h"
#include <string.h>
#include <IOKit/IOKitLib.h>

typedef struct { char major, minor, build, reserved[1]; UInt16 release; } SMCVers;
typedef struct { UInt16 version, length; UInt32 cpuPLimit, gpuPLimit, memPLimit; } SMCPLimit;
typedef struct { UInt32 dataSize; UInt32 dataType; char dataAttributes; } SMCKeyInfo;
typedef struct {
    UInt32 key; SMCVers vers; SMCPLimit pLimitData; SMCKeyInfo keyInfo;
    char result, status, data8; UInt32 data32; unsigned char bytes[32];
} SMCKeyData;

enum { CMD_READ = 5, CMD_WRITE = 6, CMD_INDEX = 8, CMD_INFO = 9 };

static io_connect_t g_conn = 0;

#define CACHE_SIZE 1024
static struct { UInt32 key; SMCKeyInfo info; } g_cache[CACHE_SIZE];
static int g_cache_n = 0;

static UInt32 k2u(const char *s) {
    return ((UInt32)(unsigned char)s[0] << 24) | ((UInt32)(unsigned char)s[1] << 16) |
           ((UInt32)(unsigned char)s[2] << 8) | (UInt32)(unsigned char)s[3];
}

static kern_return_t smc_call(SMCKeyData *in, SMCKeyData *out) {
    size_t outSize = sizeof(SMCKeyData);
    return IOConnectCallStructMethod(g_conn, 2, in, sizeof(SMCKeyData), out, &outSize);
}

int smc_open(void) {
    if (g_conn) return 0;
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!svc) return -1;
    kern_return_t r = IOServiceOpen(svc, mach_task_self(), 0, &g_conn);
    IOObjectRelease(svc);
    return r == KERN_SUCCESS ? 0 : -1;
}

void smc_close(void) {
    if (g_conn) { IOServiceClose(g_conn); g_conn = 0; }
}

static int key_info(UInt32 key, SMCKeyInfo *info) {
    for (int i = 0; i < g_cache_n; i++)
        if (g_cache[i].key == key) { *info = g_cache[i].info; return 0; }
    SMCKeyData in, out;
    memset(&in, 0, sizeof in); memset(&out, 0, sizeof out);
    in.key = key; in.data8 = CMD_INFO;
    if (smc_call(&in, &out) != KERN_SUCCESS || out.result != 0) return -1;
    *info = out.keyInfo;
    if (g_cache_n < CACHE_SIZE) { g_cache[g_cache_n].key = key; g_cache[g_cache_n].info = out.keyInfo; g_cache_n++; }
    return 0;
}

static int read_raw(UInt32 key, SMCKeyInfo *info, unsigned char *bytes) {
    if (!g_conn || key_info(key, info) != 0) return -1;
    SMCKeyData in, out;
    memset(&in, 0, sizeof in); memset(&out, 0, sizeof out);
    in.key = key; in.keyInfo.dataSize = info->dataSize; in.data8 = CMD_READ;
    if (smc_call(&in, &out) != KERN_SUCCESS || out.result != 0) return -1;
    memcpy(bytes, out.bytes, 32);
    return 0;
}

int smc_key_count(void) {
    SMCKeyInfo info; unsigned char b[32];
    if (read_raw(k2u("#KEY"), &info, b) != 0) return 0;
    return (int)(((UInt32)b[0] << 24) | ((UInt32)b[1] << 16) | ((UInt32)b[2] << 8) | b[3]);
}

int smc_key_at(int index, char *out5) {
    if (!g_conn) return -1;
    SMCKeyData in, out;
    memset(&in, 0, sizeof in); memset(&out, 0, sizeof out);
    in.data8 = CMD_INDEX; in.data32 = (UInt32)index;
    if (smc_call(&in, &out) != KERN_SUCCESS || out.result != 0) return -1;
    UInt32 k = out.key;
    out5[0] = (char)(k >> 24); out5[1] = (char)(k >> 16); out5[2] = (char)(k >> 8); out5[3] = (char)k; out5[4] = 0;
    return 0;
}

int smc_read_double(const char *key, double *outv) {
    SMCKeyInfo info; unsigned char b[32];
    if (read_raw(k2u(key), &info, b) != 0) return -1;
    UInt32 t = info.dataType;
    if (t == k2u("flt ") && info.dataSize == 4) { float f; memcpy(&f, b, 4); *outv = f; return 0; }
    if (t == k2u("ui8 ")) { *outv = b[0]; return 0; }
    if (t == k2u("ui16")) { *outv = (b[0] << 8) | b[1]; return 0; }
    if (t == k2u("ui32")) { *outv = (double)(((UInt32)b[0] << 24) | ((UInt32)b[1] << 16) | ((UInt32)b[2] << 8) | b[3]); return 0; }
    if (t == k2u("fpe2")) { *outv = ((b[0] << 8) | b[1]) / 4.0; return 0; }
    if (t == k2u("sp78")) { *outv = (int16_t)((b[0] << 8) | b[1]) / 256.0; return 0; }
    return -1;
}

int smc_write_bytes(const char *key, const unsigned char *bytes, uint32_t size) {
    SMCKeyInfo info;
    UInt32 k = k2u(key);
    if (!g_conn || key_info(k, &info) != 0 || size > 32) return -1;
    SMCKeyData in, out;
    memset(&in, 0, sizeof in); memset(&out, 0, sizeof out);
    in.key = k; in.data8 = CMD_WRITE; in.keyInfo.dataSize = info.dataSize;
    memcpy(in.bytes, bytes, size);
    if (smc_call(&in, &out) != KERN_SUCCESS || out.result != 0) return -1;
    return 0;
}

int smc_write_u8(const char *key, uint8_t v) { return smc_write_bytes(key, &v, 1); }
int smc_write_float(const char *key, float v) {
    unsigned char b[4]; memcpy(b, &v, 4); return smc_write_bytes(key, b, 4);
}
