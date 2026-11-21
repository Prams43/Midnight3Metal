# iOS guest-memory feasibility app

This isolated iOS app exercises the address-space assumptions used by the MC3 guest-memory implementation. It attempts to reserve the 4 GiB window at `0x100000000`, backs 64 MiB with an unlinked sandbox temporary file, maps that file at the guest contiguous and write-combine offsets, and checks that writes through one alias are visible through the other. It also runs the POSIX guest-page sequence used by `memory.cpp` on an untouched page outside the RAM aliases: `mprotect(RW)`, write/read, `madvise(MADV_DONTNEED)`, `mprotect(PROT_NONE)`, then recommit and check zero-fill. It releases the mappings before returning.

The probe is deliberately separate from the game target and contains no game assets or generated game code. It is an early feasibility signal, not proof that the full runtime is safe: it does not exercise allocator bookkeeping, repeated/overlapping ranges, real workload, memory pressure, or all supported device/iOS combinations. Run it under realistic memory pressure on each supported device before relying on this layout.

The probe is a diagnostic, not an installable game or a signed distribution app. No iPhone build or runtime result has been recorded yet.

Implementation note: `memory.cpp` currently ignores the return value from `madvise` in `Decommit`; this probe treats discard failure as a failed memory gate because zero-fill after recommit is part of the expected behavior. Confirm the numeric `MADV_DONTNEED` value against the selected Apple SDK before interpreting device results.

## Build on macOS

From the repository root, configure with an iOS CMake toolchain that sets `CMAKE_SYSTEM_NAME=iOS` and provides the desired SDK/device architecture, then build `MC3MemoryProbe` and install the resulting app bundle on a physical iPhone. For example, with a caller-provided toolchain file:

```sh
cmake -S . -B build-ios-probe -DCMAKE_TOOLCHAIN_FILE=/path/to/ios.toolchain.cmake
cmake --build build-ios-probe --target MC3MemoryProbe
```

The root CMake file routes iOS configurations to this standalone target and refuses to configure the Windows-only game host as an iOS app. The exact toolchain and signing/install method depend on the macOS/Xcode setup. Inspect the Xcode device console for the per-step `MC3 iOS memory probe` PASS/FAIL lines. The app displays the overall result on screen.
