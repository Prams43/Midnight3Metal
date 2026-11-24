# Guest Memory iOS Fix

## Problem
`sdk/runtime/kernel/memory.cpp` line 113-119 rejected non-exact mmap base address on iOS:
```cpp
void* const requested_base = reinterpret_cast<void*>(0x100000000ull);
p = mmap(requested_base, size, PROT_NONE, kReserveFlags, -1, 0);
if (p != MAP_FAILED && p != requested_base) {
    munmap(p, size);
    p = MAP_FAILED;  // REJECTED if iOS gave different address
}
```

iOS memory probe showed OS returned `0x7000000000` instead of requested `0x100000000`. Code rejected this and failed `Init()`.

## Root Cause
Code treated mmap address hint as requirement. iOS ignores hint, picks address from available space.

## Solution
**Removed strict address check** - accept any base address iOS provides.

Guest addresses stay 32-bit (0x80000000 etc). Translation layer adds `g_base` dynamically via `Base() + offset`. Whether base is 0x100000000 or 0x7000000000 doesn't affect guest VA math.

## Changed Code
File: `sdk/runtime/kernel/memory.cpp` lines 110-120

Removed rejection block:
```cpp
if (p != MAP_FAILED && p != requested_base) {
    munmap(p, size);
    p = MAP_FAILED;
}
```

Added comment explaining iOS accepts any base, translation handles offset.

## Verification
- Grep confirmed no hardcoded host pointer arithmetic (no `0x1[0-9a-f]{8}` literals in pointer ops)
- All VA→host translation goes through `Base()` function
- Guest code uses 32-bit addresses unchanged
- Physical memory windows (0x80000000, 0xF0000000) mapped at correct offsets from dynamic base

## Status
Fixed in memory.cpp. Not yet tested - requires iOS CI build with game runtime linked.
