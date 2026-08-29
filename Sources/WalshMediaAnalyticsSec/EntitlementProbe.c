#include "WalshMediaAnalyticsSec.h"

#include <CoreFoundation/CoreFoundation.h>
#include <libkern/OSByteOrder.h>
#include <mach-o/fat.h>
#include <mach-o/loader.h>
#include <mach/machine.h>
#include <fcntl.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#define CSMAGIC_EMBEDDED_SIGNATURE 0xfade0cc0u
#define CSMAGIC_EMBEDDED_ENTITLEMENTS 0xfade7171u
#define CSMAGIC_EMBEDDED_DER_ENTITLEMENTS 0xfade7172u

static uint32_t load32(const uint8_t *p) {
    uint32_t value;
    memcpy(&value, p, sizeof(value));
    return value;
}

static uint32_t host32(const uint8_t *p, bool swap) {
    uint32_t value = load32(p);
    return swap ? OSSwapInt32(value) : value;
}

static uint32_t be32(const uint8_t *p) {
    return OSSwapBigToHostInt32(load32(p));
}

static bool in_bounds(size_t offset, size_t length, size_t total) {
    return length <= total && offset <= total - length;
}

static bool plist_has_beta(const void *bytes, size_t length) {
    if (bytes == NULL || length == 0) {
        return false;
    }
    CFDataRef data = CFDataCreate(kCFAllocatorDefault, bytes, (CFIndex)length);
    if (data == NULL) {
        return false;
    }
    CFErrorRef error = NULL;
    CFPropertyListRef plist = CFPropertyListCreateWithData(
        kCFAllocatorDefault,
        data,
        kCFPropertyListImmutable,
        NULL,
        &error
    );
    CFRelease(data);
    if (error != NULL) {
        CFRelease(error);
    }
    if (plist == NULL) {
        return false;
    }

    bool active = false;
    if (CFGetTypeID(plist) == CFDictionaryGetTypeID()) {
        CFTypeRef value = CFDictionaryGetValue((CFDictionaryRef)plist, CFSTR("beta-reports-active"));
        if (value != NULL) {
            CFTypeID type = CFGetTypeID(value);
            if (type == CFBooleanGetTypeID()) {
                active = CFBooleanGetValue((CFBooleanRef)value);
            } else if (type == CFNumberGetTypeID()) {
                int number = 0;
                if (CFNumberGetValue((CFNumberRef)value, kCFNumberIntType, &number)) {
                    active = number != 0;
                }
            }
        }
    }
    CFRelease(plist);
    return active;
}

static bool der_has_beta_key(const uint8_t *bytes, size_t length) {
    static const char key[] = "beta-reports-active";
    const size_t key_len = sizeof(key) - 1;
    if (length < key_len) {
        return false;
    }
    for (size_t i = 0; i <= length - key_len; i++) {
        if (memcmp(bytes + i, key, key_len) == 0) {
            return true;
        }
    }
    return false;
}

bool WalshMediaEntitlementsDataHasBetaReportsActive(const void *bytes, size_t length) {
    if (plist_has_beta(bytes, length)) {
        return true;
    }
    return der_has_beta_key(bytes, length);
}

static bool blob_has_beta(const uint8_t *blob, size_t remaining) {
    if (remaining < 8) {
        return false;
    }
    uint32_t magic = be32(blob);
    uint32_t length = be32(blob + 4);
    if (length < 8 || length > remaining) {
        return false;
    }
    const uint8_t *payload = blob + 8;
    size_t payload_len = (size_t)length - 8;
    if (magic == CSMAGIC_EMBEDDED_ENTITLEMENTS) {
        return WalshMediaEntitlementsDataHasBetaReportsActive(payload, payload_len);
    }
    if (magic == CSMAGIC_EMBEDDED_DER_ENTITLEMENTS) {
        return der_has_beta_key(payload, payload_len);
    }
    return false;
}

static bool superblob_has_beta(const uint8_t *sig, size_t sig_len) {
    if (sig_len < 12 || be32(sig) != CSMAGIC_EMBEDDED_SIGNATURE) {
        return false;
    }
    uint32_t count = be32(sig + 8);
    if (count > 1024) {
        return false;
    }
    size_t index_bytes = (size_t)count * 8;
    if (!in_bounds(12, index_bytes, sig_len)) {
        return false;
    }
    for (uint32_t i = 0; i < count; i++) {
        const uint8_t *index = sig + 12 + (size_t)i * 8;
        uint32_t offset = be32(index + 4);
        if (offset >= sig_len) {
            continue;
        }
        if (blob_has_beta(sig + offset, sig_len - offset)) {
            return true;
        }
    }
    return false;
}

static bool name16_equals(const char *field, const char *want) {
    char name[17] = {0};
    memcpy(name, field, 16);
    return strcmp(name, want) == 0;
}

static bool macho_has_beta(const uint8_t *base, size_t length) {
    if (length < sizeof(struct mach_header_64)) {
        return false;
    }
    uint32_t magic = load32(base);
    bool swap = false;
    size_t header_size = 0;
    if (magic == MH_MAGIC_64) {
        header_size = sizeof(struct mach_header_64);
    } else if (magic == MH_CIGAM_64) {
        swap = true;
        header_size = sizeof(struct mach_header_64);
    } else {
        return false;
    }

    uint32_t ncmds = host32(base + 16, swap);
    uint32_t sizeofcmds = host32(base + 20, swap);
    if (ncmds > 2048 || !in_bounds(header_size, sizeofcmds, length)) {
        return false;
    }

    const uint8_t *cursor = base + header_size;
    const uint8_t *cmds_end = cursor + sizeofcmds;
    for (uint32_t i = 0; i < ncmds; i++) {
        if ((size_t)(cmds_end - cursor) < 8) {
            break;
        }
        uint32_t cmd = host32(cursor, swap);
        uint32_t cmdsize = host32(cursor + 4, swap);
        if (cmdsize < 8 || cursor + cmdsize > cmds_end) {
            break;
        }

        if (cmd == LC_SEGMENT_64 && cmdsize >= sizeof(struct segment_command_64)) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)cursor;
            char segname[16];
            memcpy(segname, seg->segname, 16);
            if (name16_equals(segname, "__TEXT")) {
                uint32_t nsects = host32((const uint8_t *)&seg->nsects, swap);
                const uint8_t *sect = cursor + sizeof(struct segment_command_64);
                for (uint32_t s = 0; s < nsects; s++) {
                    if (sect + sizeof(struct section_64) > cursor + cmdsize) {
                        break;
                    }
                    const struct section_64 *section = (const struct section_64 *)sect;
                    char sectname[16];
                    memcpy(sectname, section->sectname, 16);
                    if (name16_equals(sectname, "__entitlements")) {
                        uint32_t offset = host32((const uint8_t *)&section->offset, swap);
                        uint64_t size = swap ? OSSwapInt64(section->size) : section->size;
                        if (in_bounds(offset, (size_t)size, length) &&
                            WalshMediaEntitlementsDataHasBetaReportsActive(base + offset, (size_t)size)) {
                            return true;
                        }
                    }
                    sect += sizeof(struct section_64);
                }
            }
        }

        if (cmd == LC_CODE_SIGNATURE && cmdsize >= sizeof(struct linkedit_data_command)) {
            uint32_t dataoff = host32(cursor + 8, swap);
            uint32_t datasize = host32(cursor + 12, swap);
            if (in_bounds(dataoff, datasize, length) &&
                superblob_has_beta(base + dataoff, datasize)) {
                return true;
            }
        }

        cursor += cmdsize;
    }
    return false;
}

#if defined(__arm64__)
static const cpu_type_t kPreferredCPU = CPU_TYPE_ARM64;
#elif defined(__x86_64__)
static const cpu_type_t kPreferredCPU = CPU_TYPE_X86_64;
#else
static const cpu_type_t kPreferredCPU = 0;
#endif

static bool fat_has_beta(const uint8_t *base, size_t length) {
    if (length < sizeof(struct fat_header)) {
        return false;
    }
    uint32_t magic = load32(base);
    bool is_64 = false;
    if (magic == FAT_MAGIC || magic == FAT_CIGAM) {
        is_64 = false;
    } else if (magic == FAT_MAGIC_64 || magic == FAT_CIGAM_64) {
        is_64 = true;
    } else {
        return false;
    }

    uint32_t nfat = OSSwapBigToHostInt32(load32(base + 4));
    if (nfat == 0 || nfat > 16) {
        return false;
    }

    size_t arch_size = is_64 ? sizeof(struct fat_arch_64) : sizeof(struct fat_arch);
    if (!in_bounds(sizeof(struct fat_header), nfat * arch_size, length)) {
        return false;
    }

    const uint8_t *preferred = NULL;
    size_t preferred_len = 0;
    const uint8_t *fallback = NULL;
    size_t fallback_len = 0;

    for (uint32_t i = 0; i < nfat; i++) {
        const uint8_t *arch = base + sizeof(struct fat_header) + (size_t)i * arch_size;
        cpu_type_t cpu;
        uint64_t offset;
        uint64_t size;
        if (is_64) {
            const struct fat_arch_64 *fa = (const struct fat_arch_64 *)arch;
            cpu = (cpu_type_t)OSSwapBigToHostInt32(fa->cputype);
            offset = OSSwapBigToHostInt64(fa->offset);
            size = OSSwapBigToHostInt64(fa->size);
        } else {
            const struct fat_arch *fa = (const struct fat_arch *)arch;
            cpu = (cpu_type_t)OSSwapBigToHostInt32(fa->cputype);
            offset = OSSwapBigToHostInt32(fa->offset);
            size = OSSwapBigToHostInt32(fa->size);
        }
        if (!in_bounds((size_t)offset, (size_t)size, length)) {
            continue;
        }
        const uint8_t *slice = base + (size_t)offset;
        if (fallback == NULL) {
            fallback = slice;
            fallback_len = (size_t)size;
        }
        if (kPreferredCPU != 0 && cpu == kPreferredCPU) {
            preferred = slice;
            preferred_len = (size_t)size;
        }
    }

    if (preferred != NULL && macho_has_beta(preferred, preferred_len)) {
        return true;
    }
    if (fallback != NULL && fallback != preferred) {
        return macho_has_beta(fallback, fallback_len);
    }
    return preferred != NULL && macho_has_beta(preferred, preferred_len);
}

bool WalshMediaExecutableHasBetaReportsActive(const char *path) {
    if (path == NULL || path[0] == '\0') {
        return false;
    }

    int fd = open(path, O_RDONLY);
    if (fd < 0) {
        return false;
    }
    struct stat st;
    if (fstat(fd, &st) != 0 || st.st_size <= 0) {
        close(fd);
        return false;
    }
    size_t length = (size_t)st.st_size;
    void *mapped = mmap(NULL, length, PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd);
    if (mapped == MAP_FAILED) {
        return false;
    }

    const uint8_t *base = mapped;
    bool active = false;
    uint32_t magic = load32(base);
    if (magic == FAT_MAGIC || magic == FAT_CIGAM || magic == FAT_MAGIC_64 || magic == FAT_CIGAM_64) {
        active = fat_has_beta(base, length);
    } else {
        active = macho_has_beta(base, length);
    }
    munmap(mapped, length);
    return active;
}
