#include "smc.h"
#include <string.h>

#define KERNEL_INDEX_SMC      2
#define SMC_CMD_READ_BYTES    5
#define SMC_CMD_WRITE_BYTES   6
#define SMC_CMD_READ_KEYINFO  9

typedef struct {
    char     major;
    char     minor;
    char     build;
    char     reserved[1];
    uint16_t release;
} SMCKeyData_vers_t;

typedef struct {
    uint16_t version;
    uint16_t length;
    uint32_t cpuPLimit;
    uint32_t gpuPLimit;
    uint32_t memPLimit;
} SMCKeyData_pLimitData_t;

typedef struct {
    uint32_t dataSize;
    uint32_t dataType;
    char     dataAttributes;
} SMCKeyData_keyInfo_t;

typedef struct {
    uint32_t                key;
    SMCKeyData_vers_t       vers;
    SMCKeyData_pLimitData_t pLimitData;
    SMCKeyData_keyInfo_t    keyInfo;
    char                    result;
    char                    status;
    char                    data8;
    uint32_t                data32;
    uint8_t                 bytes[32];
} SMCKeyData_t;

_Static_assert(sizeof(SMCKeyData_t) == 80, "SMCKeyData_t phải đúng 80 byte");

static uint32_t fourcc(const char *s) {
    return ((uint32_t)(uint8_t)s[0] << 24) | ((uint32_t)(uint8_t)s[1] << 16) |
           ((uint32_t)(uint8_t)s[2] << 8)  |  (uint32_t)(uint8_t)s[3];
}

static kern_return_t smc_call(io_connect_t conn, SMCKeyData_t *in, SMCKeyData_t *out) {
    size_t outSize = sizeof(SMCKeyData_t);
    return IOConnectCallStructMethod(conn, KERNEL_INDEX_SMC, in, sizeof(SMCKeyData_t), out, &outSize);
}

kern_return_t smc_open(io_connect_t *conn) {
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!service) return kIOReturnNotFound;
    kern_return_t r = IOServiceOpen(service, mach_task_self(), 0, conn);
    IOObjectRelease(service);
    return r;
}

void smc_close(io_connect_t conn) {
    IOServiceClose(conn);
}

static kern_return_t smc_key_info(io_connect_t conn, uint32_t key, SMCKeyData_keyInfo_t *info) {
    SMCKeyData_t in, out;
    memset(&in, 0, sizeof(in));
    memset(&out, 0, sizeof(out));
    in.key = key;
    in.data8 = SMC_CMD_READ_KEYINFO;
    kern_return_t r = smc_call(conn, &in, &out);
    if (r != KERN_SUCCESS) return r;
    if (out.result != 0) return kIOReturnNotFound;
    *info = out.keyInfo;
    return KERN_SUCCESS;
}

kern_return_t smc_read_key(io_connect_t conn, const char *key, SMCValue *value) {
    if (!key || strlen(key) != 4) return kIOReturnBadArgument;
    SMCKeyData_keyInfo_t info;
    kern_return_t r = smc_key_info(conn, fourcc(key), &info);
    if (r != KERN_SUCCESS) return r;
    if (info.dataSize == 0 || info.dataSize > 32) return kIOReturnNotFound;

    SMCKeyData_t in, out;
    memset(&in, 0, sizeof(in));
    memset(&out, 0, sizeof(out));
    in.key = fourcc(key);
    in.keyInfo.dataSize = info.dataSize;
    in.data8 = SMC_CMD_READ_BYTES;
    r = smc_call(conn, &in, &out);
    if (r != KERN_SUCCESS) return r;
    if (out.result != 0) return kIOReturnError;

    memset(value, 0, sizeof(*value));
    value->dataSize = info.dataSize;
    value->dataType = info.dataType;
    memcpy(value->bytes, out.bytes, info.dataSize);
    return KERN_SUCCESS;
}

kern_return_t smc_write_key(io_connect_t conn, const char *key, const uint8_t *bytes, uint32_t size) {
    if (!key || strlen(key) != 4 || size == 0 || size > 32) return kIOReturnBadArgument;
    SMCKeyData_keyInfo_t info;
    kern_return_t r = smc_key_info(conn, fourcc(key), &info);
    if (r != KERN_SUCCESS) return r;
    if (info.dataSize != size) return kIOReturnBadArgument;

    SMCKeyData_t in, out;
    memset(&in, 0, sizeof(in));
    memset(&out, 0, sizeof(out));
    in.key = fourcc(key);
    in.data8 = SMC_CMD_WRITE_BYTES;
    in.keyInfo.dataSize = size;
    memcpy(in.bytes, bytes, size);
    r = smc_call(conn, &in, &out);
    if (r != KERN_SUCCESS) return r;
    if (out.result != 0) return kIOReturnNotPrivileged;
    return KERN_SUCCESS;
}
