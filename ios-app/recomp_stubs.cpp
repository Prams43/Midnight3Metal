// recomp_stubs.cpp — stub definitions for recompiler-generated symbols.
// The real definitions come from the per-XBE compiled .cpp files produced by
// sdk/tools/recomp.  Until default.xbe is recompiled and linked, these stubs
// allow the iOS runtime to link and show the kernel/xdk layer is wired up.
//
// When Boot() is called with a real XBE, it verifies X86EntryPoint matches;
// if the stubs are still present (0 entry) Boot() will LOGE and return false.

#include <cstdint>
#include "cpu/x86_ops.h"
#include "xdk/hle.h"

// Recompiler outputs these in the generated <image>.cpp:
//   extern const X86FuncMapping X86FuncMappings[];  // null-terminated
//   extern const uint32_t X86Continuations[];        // zero-terminated
//   extern const uint32_t X86CodeBase, X86CodeEnd, X86ImageBase, X86ImageEnd;
//   extern const uint32_t X86EntryPoint, X86KernelThunk;

// Stub: empty function table (single null sentinel)
extern "C" const X86FuncMapping X86FuncMappings[] = { {0, nullptr} };

// Stub: empty continuation list
extern "C" const uint32_t X86Continuations[] = { 0 };

// Stub: code range covers nothing (lo == hi means nothing to dispatch)
extern "C" const uint32_t X86CodeBase   = 0x00010000u;
extern "C" const uint32_t X86CodeEnd    = 0x00010000u;
extern "C" const uint32_t X86ImageBase  = 0x00010000u;
extern "C" const uint32_t X86ImageEnd   = 0x00010000u;

// Stub: entry point 0 — Boot() will reject any XBE that does not match.
extern "C" const uint32_t X86EntryPoint  = 0x00000000u;
extern "C" const uint32_t X86KernelThunk = 0x00000000u;

// Stub original guest implementations referenced via GUEST_ORIG()
X86_FUNC(GUEST_ORIG(BinkGetSummary))   { (void)ctx; (void)base; }
X86_FUNC(GUEST_ORIG(BinkDoFrame))      { (void)ctx; (void)base; }
X86_FUNC(GUEST_ORIG(BinkNextFrame))    { (void)ctx; (void)base; }
X86_FUNC(GUEST_ORIG(XLaunchNewImageA)) { (void)ctx; (void)base; }
