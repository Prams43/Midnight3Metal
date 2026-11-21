// Standalone iOS diagnostic for the guest address-space assumptions in memory.cpp.
// Compiled only into the temporary iOS feasibility app, never the game.
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

#if defined(__APPLE__) && !defined(MADV_DONTNEED)
#define MADV_DONTNEED 4
#endif

namespace {
constexpr uint64_t kGuestWindowSize = 1ull << 32;
constexpr uint32_t kPhysicalSize = 64u << 20;
constexpr uint32_t kContiguousBase = 0x80000000u;
constexpr uint32_t kWriteCombineBase = 0xF0000000u;

void SetFailure(char* output, size_t capacity, const char* step, int error = 0) {
    if (output == nullptr || capacity == 0) return;
    if (error != 0) {
        std::snprintf(output, capacity, "%s failed (errno %d: %s)",
                      step, error, std::strerror(error));
    } else {
        std::snprintf(output, capacity, "%s failed", step);
    }
}

void Log(const char* label, bool ok, int error = 0) {
    std::fprintf(stderr, "MC3 iOS memory probe: %s: %s (errno=%d: %s)\n", label,
                 ok ? "PASS" : "FAIL", error, error ? std::strerror(error) : "none");
}
}

// Returns a concrete first-failure message for display in the app. The requested
// base is passed only as a hint: never use MAP_FIXED for the 4 GiB reservation.
extern "C" bool MC3RunIOSMemoryProbe(char* failure, size_t failureCapacity) {
    if (failure != nullptr && failureCapacity != 0) failure[0] = '\0';

    void* const requestedBase = reinterpret_cast<void*>(0x100000000ull);
    void* reservation = mmap(requestedBase, kGuestWindowSize, PROT_NONE,
                             MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (reservation == MAP_FAILED) {
        const int e = errno;
        Log("4 GiB reservation", false, e);
        SetFailure(failure, failureCapacity, "4 GiB reservation", e);
        return false;
    }
    const bool exact = reservation == requestedBase;
    Log("4 GiB reservation at requested 0x100000000", exact);
    if (!exact) {
        char detail[96];
        std::snprintf(detail, sizeof(detail), "iOS chose 0x%llx, requested 0x100000000",
                      static_cast<unsigned long long>(reinterpret_cast<uintptr_t>(reservation)));
        if (failure != nullptr && failureCapacity != 0)
            std::snprintf(failure, failureCapacity, "4 GiB address: %s", detail);
        munmap(reservation, kGuestWindowSize);
        return false;
    }

    auto failAndRelease = [&](const char* step, int error = 0) {
        SetFailure(failure, failureCapacity, step, error);
        munmap(reservation, kGuestWindowSize);
        return false;
    };

    std::error_code ec;
    const auto temp = std::filesystem::temp_directory_path(ec);
    if (ec) {
        Log("sandbox temporary directory", false, ec.value());
        return failAndRelease("sandbox temporary directory", ec.value());
    }
    std::string pattern = (temp / "mc3-memory-probe-XXXXXX").string();
    std::vector<char> path(pattern.begin(), pattern.end());
    path.push_back('\0');
    const int fd = mkstemp(path.data());
    if (fd < 0) {
        const int e = errno;
        Log("temporary shared backing file", false, e);
        return failAndRelease("temporary shared backing file", e);
    }
    unlink(path.data());
    if (ftruncate(fd, kPhysicalSize) != 0) {
        const int e = errno;
        close(fd);
        Log("64 MiB backing file", false, e);
        return failAndRelease("64 MiB backing file", e);
    }

    auto* bytes = static_cast<uint8_t*>(reservation);
    void* first = mmap(bytes + kContiguousBase, kPhysicalSize, PROT_READ | PROT_WRITE,
                       MAP_SHARED | MAP_FIXED, fd, 0);
    if (first == MAP_FAILED) {
        const int e = errno;
        close(fd);
        Log("first shared alias", false, e);
        return failAndRelease("first shared alias", e);
    }
    void* second = mmap(bytes + kWriteCombineBase, kPhysicalSize, PROT_READ | PROT_WRITE,
                        MAP_SHARED | MAP_FIXED, fd, 0);
    if (second == MAP_FAILED) {
        const int e = errno;
        close(fd);
        Log("second shared alias", false, e);
        return failAndRelease("second shared alias", e);
    }
    close(fd);
    Log("shared physical aliases", true);

    constexpr uint8_t marker = 0xA5;
    bytes[kContiguousBase + 0x1234] = marker;
    const bool aliasesShareData = bytes[kWriteCombineBase + 0x1234] == marker;
    Log("alias coherence", aliasesShareData);
    if (!aliasesShareData) return failAndRelease("alias coherence");

    constexpr size_t kGuestPageSize = 4096;
    constexpr uint64_t kGuestTestOffset = 0x40000000ull;
    auto* guestPage = bytes + kGuestTestOffset;

    if (mprotect(guestPage, kGuestPageSize, PROT_READ | PROT_WRITE) != 0) {
        const int e = errno;
        Log("guest page commit (mprotect RW)", false, e);
        return failAndRelease("guest page commit (mprotect RW)", e);
    }
    Log("guest page commit (mprotect RW)", true);
    guestPage[0] = 0x3C;
    guestPage[kGuestPageSize - 1] = 0xC3;
    const bool writable = guestPage[0] == 0x3C && guestPage[kGuestPageSize - 1] == 0xC3;
    Log("committed guest page read/write", writable);
    if (!writable) return failAndRelease("committed guest page read/write");

    if (madvise(guestPage, kGuestPageSize, MADV_DONTNEED) != 0) {
        const int e = errno;
        Log("guest page discard (madvise DONTNEED)", false, e);
        return failAndRelease("guest page discard (madvise DONTNEED)", e);
    }
    Log("guest page discard (madvise DONTNEED)", true);

    if (mprotect(guestPage, kGuestPageSize, PROT_NONE) != 0) {
        const int e = errno;
        Log("guest page decommit (mprotect NONE)", false, e);
        return failAndRelease("guest page decommit (mprotect NONE)", e);
    }
    Log("guest page decommit (mprotect NONE)", true);

    if (mprotect(guestPage, kGuestPageSize, PROT_READ | PROT_WRITE) != 0) {
        const int e = errno;
        Log("guest page recommit (mprotect RW)", false, e);
        return failAndRelease("guest page recommit (mprotect RW)", e);
    }
    Log("guest page recommit (mprotect RW)", true);
    const bool recommitClean = guestPage[0] == 0 && guestPage[kGuestPageSize - 1] == 0;
    Log("recommitted guest page zero-fill", recommitClean);
    if (!recommitClean) return failAndRelease("recommitted guest page zero-fill");

    if (mprotect(guestPage, kGuestPageSize, PROT_NONE) != 0) {
        const int e = errno;
        Log("restore guest page to PROT_NONE", false, e);
        return failAndRelease("restore guest page to PROT_NONE", e);
    }
    Log("restore guest page to PROT_NONE", true);

    munmap(reservation, kGuestWindowSize);
    return true;
}
#endif  // TARGET_OS_IPHONE
#endif  // defined(__APPLE__)
