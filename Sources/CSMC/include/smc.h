#ifndef CSMC_SMC_H
#define CSMC_SMC_H

#include <IOKit/IOKitLib.h>
#include <stdint.h>

typedef struct {
    uint32_t dataSize;
    uint32_t dataType;        // FourCC, ví dụ 'ui8 ', 'flt ', 'hex_'
    uint8_t  dataAttributes;  // 0x80 đọc được, 0x40 ghi được, 0x04 little-endian (Apple Silicon)
    uint8_t  bytes[32];
} SMCValue;

/// Mở kết nối tới AppleSMC. Trả về KERN_SUCCESS nếu thành công.
kern_return_t smc_open(io_connect_t *conn);
void smc_close(io_connect_t conn);

/// Đọc key 4 ký tự (ví dụ "CH0B"). Trả về kIOReturnNotFound nếu key không tồn tại,
/// lỗi của IOKit (ví dụ kIOReturnNotPrivileged) nếu bị từ chối, kIOReturnError nếu SMC báo lỗi khác.
kern_return_t smc_read_key(io_connect_t conn, const char *key, SMCValue *out);

/// Ghi key. `size` phải khớp với dataSize của key (cần quyền root).
kern_return_t smc_write_key(io_connect_t conn, const char *key, const uint8_t *bytes, uint32_t size);

#endif
