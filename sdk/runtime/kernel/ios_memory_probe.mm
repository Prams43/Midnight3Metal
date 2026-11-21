// Standalone iOS diagnostic for the guest address-space assumptions in memory.cpp.
// This file is compiled only into the temporary iOS feasibility app, never the game.
#if defined(__APPLE__)
#include <TargetConditionals.h>
#if TARGET_OS_IPHONE
#import <Foundation/Foundation.h>
#include <sys/mman.h>
#include <unistd.h>
#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <string>
#include <system_error>
#include <vector>

// Darwin headers may not expose this Linux-named constant; Apple documents the
// same advice value as MADV_DONTNEED on supported Darwin SDKs.
#if defined(__APPLE__) && !defined(MADV_DONTNEED)
#define MADV_DONTNEED 4
#endif

namespace {
constexpr uint64_t kGuestWindowSize = 1ull << 32;
constexpr uint32_t kPhysicalSize = 64u << 20;
constexpr uint32_t kContiguousBase = 0x80000000u;
constexpr uint32_t kWriteCombineBase = 0xF0000000u;

void Log(const char* label, bool ok, int error = 0) {
    std::fprintf(stderr, "MC3 iOS memory probe: %s: %s (errno=%d: %s)\n", label,
                 ok ? "PASS" : "FAIL", error, error ? std::strerror(error) : "none");
}
}

// Returns true only if a 4 GiB reservation at the production address, both shared
// physical aliases, and the production guest-page commit/decommit cycle work.
// Always releases every mapping/file.
extern "C" bool MC3RunIOSMemoryProbe(void) {
    void* const base = reinterpret_cast<void*>(0x100000000ull);
    void* reservation = mmap(base, kGuestWindowSize, PROT_NONE,
                             MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (reservation == MAP_FAILED) {
        const int e = errno;
        Log("4 GiB fixed reservation", false, e);
        return false;
    }
    const bool exact = reservation == base;
    Log("4 GiB fixed reservation at 0x100000000", exact);
    if (!exact) {
        munmap(reservation, kGuestWindowSize);
        return false;
    }

    std::error_code ec;
    const auto temp = std::filesystem::temp_directory_path(ec);
    if (ec) {
        Log("sandbox temporary directory", false, ec.value());
        munmap(reservation, kGuestWindowSize);
        return false;
    }
    std::string pattern = (temp / "mc3-memory-probe-XXXXXX").string();
    std::vector<char> path(pattern.begin(), pattern.end());
    path.push_back('\0');
    const int fd = mkstemp(path.data());
    if (fd < 0) {
        const int e = errno;
        Log("temporary shared backing file", false, e);
        munmap(reservation, kGuestWindowSize);
        return false;
    }
    unlink(path.data());
    if (ftruncate(fd, kPhysicalSize) != 0) {
        const int e = errno;
        close(fd);
        munmap(reservation, kGuestWindowSize);
        Log("64 MiB backing file", false, e);
        return false;
    }

    auto* bytes = static_cast<uint8_t*>(reservation);
    void* first = mmap(bytes + kContiguousBase, kPhysicalSize, PROT_READ | PROT_WRITE,
                       MAP_SHARED | MAP_FIXED, fd, 0);
    void* second = MAP_FAILED;
    if (first == bytes + kContiguousBase) {
        second = mmap(bytes + kWriteCombineBase, kPhysicalSize, PROT_READ | PROT_WRITE,
                      MAP_SHARED | MAP_FIXED, fd, 0);
    }
    const int mapping_error = (first == bytes + kContiguousBase &&
                               second == bytes + kWriteCombineBase) ? 0 : errno;
    close(fd);

    const bool aliases_mapped = first == bytes + kContiguousBase && second == bytes + kWriteCombineBase;
    Log("shared physical aliases", aliases_mapped, mapping_error);
    bool aliases_share_data = false;
    if (aliases_mapped) {
        constexpr uint8_t marker = 0xA5;
        bytes[kContiguousBase + 0x1234] = marker;
        aliases_share_data = bytes[kWriteCombineBase + 0x1234] == marker;
        Log("alias coherence", aliases_share_data);
    }

    // Match memory.cpp's POSIX Commit/Decommit sequence on an untouched page
    // outside both physical aliases: mprotect(RW), madvise(DONTNEED), mprotect(NONE).
    bool guest_commit_cycle = false;
    if (aliases_mapped && aliases_share_data) {
        constexpr size_t kGuestPageSize = 4096;
        constexpr uint64_t kGuestTestOffset = 0x40000000ull;
        auto* guest_page = bytes + kGuestTestOffset;
        const bool committed = mprotect(guest_page, kGuestPageSize,
                                        PROT_READ | PROT_WRITE) == 0;
        Log("guest page commit (mprotect RW)", committed, committed ? 0 : errno);
        if (committed) {
            guest_page[0] = 0x3C;
            guest_page[kGuestPageSize - 1] = 0xC3;
            const bool writable = guest_page[0] == 0x3C &&
                                  guest_page[kGuestPageSize - 1] == 0xC3;
            Log("committed guest page read/write", writable);

            const bool discarded = madvise(guest_page, kGuestPageSize, MADV_DONTNEED) == 0;
            Log("guest page discard (madvise DONTNEED)", discarded, discarded ? 0 : errno);
            bool decommitted = false;
            bool recommitted = false;
            bool recommit_clean = false;
            if (discarded) {
                decommitted = mprotect(guest_page, kGuestPageSize, PROT_NONE) == 0;
                Log("guest page decommit (mprotect NONE)", decommitted,
                    decommitted ? 0 : errno);
                if (decommitted) {
                    recommitted = mprotect(guest_page, kGuestPageSize,
                                           PROT_READ | PROT_WRITE) == 0;
                    Log("guest page recommit (mprotect RW)", recommitted,
                        recommitted ? 0 : errno);
                    if (recommitted) {
                        recommit_clean = guest_page[0] == 0 &&
                                         guest_page[kGuestPageSize - 1] == 0;
                        Log("recommitted guest page zero-fill", recommit_clean);
                    }
                }
            }
            // Restore the reservation's original protection regardless of failures.
            if (mprotect(guest_page, kGuestPageSize, PROT_NONE) != 0) {
                Log("restore guest page to PROT_NONE", false, errno);
            } else {
                guest_commit_cycle = writable && discarded && decommitted &&
                                     recommitted && recommit_clean;
            }
        }
    }

    munmap(reservation, kGuestWindowSize);
    return aliases_mapped && aliases_share_data && guest_commit_cycle;
}
#endif  // TARGET_OS_IPHONE
#endif  // defined(__APPLE__)
