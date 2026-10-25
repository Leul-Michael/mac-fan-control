// Minimal access to the Apple System Management Controller (SMC) through IOKit.
// The SMC holds the fan and temperature "keys" (four-character codes such as F0Ac).
#ifndef SMC_H
#define SMC_H

#include <stdint.h>
#include <stdbool.h>
#include <IOKit/IOKitLib.h>

typedef struct {
    uint32_t size;     // bytes of data
    uint32_t type;     // four-character type code, e.g. 'flt ', 'ui8 '
    uint8_t attributes;
} smc_key_info;

/// Opens the AppleSMC service. Returns 0 (kIOReturnSuccess) on success.
kern_return_t smc_open(io_connect_t *connection);
void smc_close(io_connect_t connection);

kern_return_t smc_key_count(io_connect_t connection, uint32_t *count);
/// The key at `index` (0 ..< count), as a four-character code.
kern_return_t smc_key_at(io_connect_t connection, uint32_t index, uint32_t *key);
kern_return_t smc_info(io_connect_t connection, uint32_t key, smc_key_info *info);
/// Reads up to 32 bytes. `size` receives the key's data size.
kern_return_t smc_read(io_connect_t connection, uint32_t key, uint8_t bytes[32], smc_key_info *info);
/// Writes `size` bytes; needs root.
kern_return_t smc_write(io_connect_t connection, uint32_t key, const uint8_t *bytes, uint32_t size);

#endif
