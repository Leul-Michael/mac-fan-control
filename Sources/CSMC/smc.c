#include "smc.h"
#include <string.h>

// Layout expected by the AppleSMC user client (80 bytes), as used by long-standing open-source tools.
typedef struct { uint8_t major, minor, build, reserved; uint16_t release; } smc_vers;
typedef struct { uint16_t version, length; uint32_t cpu, gpu, mem; } smc_plimit;
typedef struct { uint32_t size, type; uint8_t attributes; } smc_info_raw;
typedef struct {
    uint32_t key;
    smc_vers vers;
    smc_plimit plimit;
    smc_info_raw info;
    uint8_t result, status, command;
    uint32_t data32;
    uint8_t bytes[32];
} smc_param;

enum { SMC_HANDLE_EVENT = 2, CMD_READ = 5, CMD_WRITE = 6, CMD_INDEX = 8, CMD_INFO = 9 };

static kern_return_t call(io_connect_t c, smc_param *in, smc_param *out) {
    size_t size = sizeof(smc_param);
    kern_return_t r = IOConnectCallStructMethod(c, SMC_HANDLE_EVENT, in, sizeof(smc_param), out, &size);
    if (r != kIOReturnSuccess) return r;
    return out->result == 0 ? kIOReturnSuccess : kIOReturnError;
}

kern_return_t smc_open(io_connect_t *connection) {
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!service) return kIOReturnNotFound;
    kern_return_t r = IOServiceOpen(service, mach_task_self(), 0, connection);
    IOObjectRelease(service);
    return r;
}

void smc_close(io_connect_t connection) { IOServiceClose(connection); }

kern_return_t smc_info(io_connect_t c, uint32_t key, smc_key_info *info) {
    smc_param in = {0}, out = {0};
    in.key = key;
    in.command = CMD_INFO;
    kern_return_t r = call(c, &in, &out);
    if (r == kIOReturnSuccess) {
        info->size = out.info.size;
        info->type = out.info.type;
        info->attributes = out.info.attributes;
    }
    return r;
}

kern_return_t smc_read(io_connect_t c, uint32_t key, uint8_t bytes[32], smc_key_info *info) {
    kern_return_t r = smc_info(c, key, info);
    if (r != kIOReturnSuccess) return r;
    smc_param in = {0}, out = {0};
    in.key = key;
    in.info.size = info->size;
    in.command = CMD_READ;
    r = call(c, &in, &out);
    if (r == kIOReturnSuccess) memcpy(bytes, out.bytes, 32);
    return r;
}

kern_return_t smc_write(io_connect_t c, uint32_t key, const uint8_t *bytes, uint32_t size) {
    if (size > 32) return kIOReturnBadArgument;
    smc_param in = {0}, out = {0};
    in.key = key;
    in.info.size = size;
    in.command = CMD_WRITE;
    memcpy(in.bytes, bytes, size);
    return call(c, &in, &out);
}

kern_return_t smc_key_count(io_connect_t c, uint32_t *count) {
    uint8_t bytes[32];
    smc_key_info info;
    kern_return_t r = smc_read(c, '#KEY', bytes, &info);
    if (r == kIOReturnSuccess) *count = (uint32_t)bytes[0] << 24 | (uint32_t)bytes[1] << 16 | (uint32_t)bytes[2] << 8 | bytes[3];
    return r;
}

kern_return_t smc_key_at(io_connect_t c, uint32_t index, uint32_t *key) {
    smc_param in = {0}, out = {0};
    in.command = CMD_INDEX;
    in.data32 = index;
    kern_return_t r = call(c, &in, &out);
    if (r == kIOReturnSuccess) *key = out.key;
    return r;
}
