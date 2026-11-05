#ifndef STATBAR_SMC_H
#define STATBAR_SMC_H
#include <stdint.h>

int  smc_open(void);
void smc_close(void);
/* number of SMC keys, and key name at index (out must hold 5 bytes) */
int  smc_key_count(void);
int  smc_key_at(int index, char *out);
/* reads key as a double (handles flt, ui8/16/32, fpe2, sp78). returns 0 on success */
int  smc_read_double(const char *key, double *out);
/* raw write, returns 0 on success (requires root) */
int  smc_write_bytes(const char *key, const unsigned char *bytes, uint32_t size);
int  smc_write_u8(const char *key, uint8_t v);
int  smc_write_float(const char *key, float v);

#endif
