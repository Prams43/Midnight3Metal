#import "ViewController.h"
#import "app/ios_touch_controls.h"
#import "MC3DebugOverlay.h"
#include "audio/audio.h"
#include "core/input.h"
#include "core/log.h"
#include "cpu/x86_context.h"
#include "gpu/backend.h"
#include "gpu/metal.h"
#include "kernel/kernel.h"
#include "kernel/memory.h"
#import <QuartzCore/CAMetalLayer.h>
#include <atomic>
#include <cstring>
#include <memory>
#include <cstdlib>
#include <signal.h>
#include <execinfo.h>
#include <unistd.h>
#include <mach-o/dyld.h>

static std::atomic<uint64_t> g_audioFrames{0};

// Crash reporter: writes signal, fault address (and the guest VA when it lies in guest memory),
// guest stack and host backtrace into the log file before the process dies.
static void MC3CrashHandler(int sig, siginfo_t* info, void*) {
    static std::atomic<int> entered{0};
    if (entered.exchange(1)) _exit(128 + sig);
    const uintptr_t addr = reinterpret_cast<uintptr_t>(info ? info->si_addr : nullptr);
    const uintptr_t base = reinterpret_cast<uintptr_t>(mem::Base());
    const uint32_t guest_va = (base && addr >= base && addr < base + 0x100000000ull) ? uint32_t(addr - base) : 0u;
    LOGE("CRASH: signal=%d code=%d addr=%p guest_va=%08X base=%p slide=%p", sig, info ? info->si_code : 0,
         reinterpret_cast<void*>(addr), guest_va,
         reinterpret_cast<void*>(base), reinterpret_cast<void*>(_dyld_get_image_vmaddr_slide(0)));
    if (guest_va) {
        mem::RegionInfo ri{};
        const bool qok = mem::QueryVirtual(guest_va, ri);
        const mem::Stats ms = mem::Query();
        LOGE("CRASH: vm committed=%d query_ok=%d base=%08X alloc=%08X size=%08X state=%08X prot=%X | phys avail=%u/%u contig=%u sys=%u virt=%u",
             mem::IsCommitted(guest_va) ? 1 : 0, qok ? 1 : 0, ri.base, ri.alloc_base, ri.size, ri.state, ri.protect,
             ms.available_pages, ms.total_pages, ms.contiguous_used, ms.system_used, ms.virtual_committed);
    }
    if (kernel::Thread* t = kernel::Current(); t && t->ctx) kernel::LogGuestStack(*t->ctx, 64);
    void* frames[40];
    const int n = backtrace(frames, 40);
    for (int i = 0; i < n; i++)
        LOGE("CRASH: frame %d %p (unslid %p)", i, frames[i],
             reinterpret_cast<void*>(reinterpret_cast<uintptr_t>(frames[i]) - _dyld_get_image_vmaddr_slide(0)));
    signal(sig, SIG_DFL);
    raise(sig);
}

static void InstallCrashHandler() {
    struct sigaction sa{};
    sa.sa_sigaction = MC3CrashHandler;
    sa.sa_flags = SA_SIGINFO;
    sigemptyset(&sa.sa_mask);
    for (int s : {SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGFPE, SIGTRAP}) sigaction(s, &sa, nullptr);
}

// UIView subclass that uses CAMetalLayer as its backing layer.
// This is the correct way to get a Metal-backed view on iOS: override +layerClass
// on the actual view class so UIKit uses it from the start, rather than adding
// a sublayer (sublayers don't get automatic compositing by the window server).
@interface MetalView : UIView
@end
@implementation MetalView
+ (Class)layerClass { return [CAMetalLayer class]; }
@end

// Bridge: redirect logx::Write output to the on-screen debug overlay.
// Called from a C-linkage shim installed at app startup.
static void OverlayLogLine(const char* line) {
    NSString* s = [NSString stringWithUTF8String:line ?: ""];
    // Trim trailing newline for display
    s = [s stringByTrimmingCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    if (s.length > 0) [MC3DebugOverlay log:s];
}

@interface ViewController ()
@property (strong, nonatomic) UIView* touchControlsOverlay;
@property (strong, nonatomic) CADisplayLink* displayLink;
@property (nonatomic) double startTime;
@property (strong, nonatomic) MC3DebugOverlay* debugOverlay;
@end

@implementation ViewController {
    std::unique_ptr<gpu::Backend> _gpuBackend;
    std::unique_ptr<gpu::State> _testState;
    uint32_t _testVbHeader;
    uint32_t _testVbData;
    BOOL _gameBooted;
}

+ (Class)layerClass {
    return [CAMetalLayer class];
}

- (void)loadView {
    // Create MetalView whose backing layer IS a CAMetalLayer.
    // MetalView overrides +layerClass so UIKit makes the layer for us.
    MetalView* metalView = [[MetalView alloc] initWithFrame:[UIScreen mainScreen].bounds];
    metalView.contentScaleFactor = [UIScreen mainScreen].scale;
    self.view = metalView;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.view.backgroundColor = [UIColor blackColor];
    self.startTime = CACurrentMediaTime();

    // Initialize logging subsystem inside the app sandbox's tmp directory
    NSString* tmpDir = NSTemporaryDirectory();
    logx::Init(tmpDir ? [tmpDir UTF8String] : "/tmp", "mc3ios");
    LOGI("MC3 iOS Host: UIKit app host started");
    InstallCrashHandler();

    // Initialize input subsystem (SDL gamepad + virtual controls)
    input::Init();
    LOGI("MC3 iOS Host: Input subsystem initialized");

    // Initialize and smoke-test portable guest memory (4 GiB virtual + shared physical alias)
    // Use 128 MB physical memory so the game heap grows to 111 MB via sub_002698C0 and does not exhaust 64 MB entering gameplay.
    mem::SetPhysicalSize(mem::kPhysicalSizeMax);
    if (mem::Init()) {
        uint8_t* base = mem::Base();
        kernel::g_base = base;
        const uint32_t va = mem::AllocContiguous(4096, 0, mem::PhysicalSize() - 1, 4096);
        bool aliasOk = false;
        if (va) {
            const uint32_t wcVa = (va - mem::kContiguousBase) + mem::kWriteCombineBase;
            auto* pContig = reinterpret_cast<volatile uint32_t*>(base + va);
            auto* pWc = reinterpret_cast<volatile uint32_t*>(base + wcVa);
            *pContig = 0x12345678u;
            aliasOk = (*pWc == 0x12345678u);
            mem::FreeContiguous(va);
        }
        NSString* memMsg = [NSString stringWithFormat:@"[MEM] base=%p alias=%s",
                            static_cast<void*>(base), aliasOk ? "PASS" : "FAIL"];
        [MC3DebugOverlay log:memMsg];
        LOGI("%s", [memMsg UTF8String]);
    } else {
        [MC3DebugOverlay log:@"[MEM] Init FAILED"];
        LOGE("MC3 iOS Host: mem::Init failed");
    }

    // Initialize Apple Audio Queue output (silent callback to verify audio thread pulls buffers)
    audio::StartOutput([](float* out, uint32_t frames) {
        std::memset(out, 0, static_cast<size_t>(frames) * 2 * sizeof(float));
        g_audioFrames.fetch_add(frames, std::memory_order_relaxed);
    });
    [MC3DebugOverlay log:@"[AUDIO] AudioQueue started"];

    // Initialize Metal layer first so d3d8's CreateBackend() can use it if kernel::Boot() succeeds.
    // The view's own layer IS the CAMetalLayer (MetalView overrides +layerClass).
    CAMetalLayer* metalLayer = nil;
    if ([self.view.layer isKindOfClass:[CAMetalLayer class]]) {
        metalLayer = (CAMetalLayer*)self.view.layer;
    } else {
        // Fallback: check sublayers (old code path)
        for (CALayer* layer in self.view.layer.sublayers) {
            if ([layer isKindOfClass:[CAMetalLayer class]]) {
                metalLayer = (CAMetalLayer*)layer;
                break;
            }
        }
    }
    if (metalLayer) {
        metalLayer.contentsScale = [UIScreen mainScreen].scale;
        gpu::SetMetalLayer((__bridge void*)metalLayer);
    } else {
        LOGE("MC3 iOS Host: CAMetalLayer not found in view");
    }

    // Check if default.xbe is present in Documents/ or app bundle
    NSArray<NSString*>* docPaths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString* docsDir = docPaths.firstObject ?: tmpDir;

    // Set environment variables for iOS before boot so game code can read them.
    // Skip MC2 intro movies (no BIK decode on iOS → black screen otherwise).
    setenv("MC3_SKIP_MC2_MOVIES", "1", 1);
    // Point MC2 career save to the app's Documents folder.
    setenv("MC3_MC2_SAVE_PATH", [[docsDir stringByAppendingPathComponent:@"mc2_career_progress.dat"] UTF8String], 1);

    NSString* xbeInDocs = [docsDir stringByAppendingPathComponent:@"default.xbe"];
    NSString* xbeInBundle = [[NSBundle mainBundle] pathForResource:@"default" ofType:@"xbe"];
    NSString* xbePath = [[NSFileManager defaultManager] fileExistsAtPath:xbeInDocs] ? xbeInDocs
                      : (xbeInBundle && [[NSFileManager defaultManager] fileExistsAtPath:xbeInBundle] ? xbeInBundle : nil);

    if (xbePath) {
        NSData* raw = [NSData dataWithContentsOfFile:xbePath];
        if (raw.length > 0) {
            std::vector<uint8_t> xbeBytes(static_cast<const uint8_t*>(raw.bytes),
                                          static_cast<const uint8_t*>(raw.bytes) + raw.length);
            std::string gameDir = [docsDir UTF8String];
            std::string dataDir = [[docsDir stringByAppendingPathComponent:@"save"] UTF8String];
            [[NSFileManager defaultManager] createDirectoryAtPath:[docsDir stringByAppendingPathComponent:@"save"]
                                      withIntermediateDirectories:YES attributes:nil error:nil];
            bool booted = kernel::Boot(std::move(xbeBytes), "default.xbe", gameDir, dataDir);
            _gameBooted = booted ? YES : NO;
            [MC3DebugOverlay log:[NSString stringWithFormat:@"[BOOT] default.xbe -> %s (ep=0x%08X)",
                                  booted ? "OK" : "FAILED", X86EntryPoint]];
        }
    } else {
        [MC3DebugOverlay log:@"[BOOT] No default.xbe (stub mode, showing test triangle)"];
    }

    // Stub mode only: when the real game is not booted, create a standalone MetalBackend for the test triangle.
    // When _gameBooted == YES, d3d8.cpp owns gpu::CreateBackend() on the game's render thread.
    if (!_gameBooted && metalLayer) {
        _gpuBackend = gpu::CreateBackend();
        if (!_gpuBackend || !_gpuBackend->Init(640, 480)) {
            _gpuBackend.reset();
            LOGE("MC3 iOS Host: Failed to initialize gpu::Backend (Metal)");
            [MC3DebugOverlay log:@"[GPU] MetalBackend FAILED"];
        } else {
            LOGI("MC3 iOS Host: gpu::Backend (Metal) initialized (stub mode)");
            [MC3DebugOverlay log:@"[GPU] MetalBackend ready (640x480)"];

            // Build a minimal pretransformed (XYZRHW | DIFFUSE) triangle in guest memory
            if (mem::Base()) {
                struct GuestVert { float x, y, z, rhw; uint32_t color; };
                _testVbData = mem::AllocContiguous(sizeof(GuestVert) * 3, 0, mem::PhysicalSize() - 1, 16);
                _testVbHeader = mem::AllocSystem(20, 16);
                if (_testVbData && _testVbHeader) {
                    auto* v = reinterpret_cast<GuestVert*>(mem::Base() + _testVbData);
                    v[0] = {320.0f, 120.0f, 0.0f, 1.0f, 0xFFFF3333u};
                    v[1] = {160.0f, 360.0f, 0.0f, 1.0f, 0xFF33FF33u};
                    v[2] = {480.0f, 360.0f, 0.0f, 1.0f, 0xFF3388FFu};
                    auto* hdr = reinterpret_cast<uint32_t*>(mem::Base() + _testVbHeader);
                    hdr[0] = 0;
                    hdr[1] = mem::PhysicalFromVirtual(_testVbData);
                    hdr[2] = 0;
                    hdr[3] = 0;
                    hdr[4] = sizeof(GuestVert) * 3;
                    _testState = std::make_unique<gpu::State>();
                    _testState->vs_handle = 0x44;  // D3DFVF_XYZRHW | D3DFVF_DIFFUSE
                    _testState->streams[0] = {_testVbHeader, sizeof(GuestVert)};
                }
            }
        }
    }

    // Create and add touch controls overlay
    self.touchControlsOverlay = app::CreateTouchControlsOverlay(self.view.bounds);
    if (self.touchControlsOverlay) {
        [self.view addSubview:self.touchControlsOverlay];
        LOGI("MC3 iOS Host: Touch controls overlay initialized");
    } else {
        LOGE("MC3 iOS Host: Failed to create touch controls overlay");
    }

    // Add debug overlay on top of everything (Windows devs: no Mac/Xcode needed)
    self.debugOverlay = [MC3DebugOverlay sharedOverlay];
    self.debugOverlay.frame = self.view.bounds;
    self.debugOverlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.debugOverlay];
    [MC3DebugOverlay log:@"[MC3] Debug overlay ready. Tap top-left to hide."];

    // Set up game loop using CADisplayLink (synced to display refresh rate)
    self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(gameLoopTick:)];
    [self.displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];

    LOGI("MC3 iOS Host: Display link game loop started");
    [MC3DebugOverlay log:@"[MC3] App started. Metal + Input + Loop ready."];
}

- (void)gameLoopTick:(CADisplayLink*)displayLink {
    double currentTime = CACurrentMediaTime() - self.startTime;

    // Render test triangle only in stub mode (when real game is not booted)
    if (!_gameBooted && _gpuBackend) {
        gpu::State clearState;
        _gpuBackend->Clear(clearState, 0, nullptr, gpu::kClearTarget, 0xFF0A1020u, 1.0f, 0);
        if (_testState) {
            _gpuBackend->Draw(*_testState, 5 /* Xbox D3DPT_TRIANGLELIST */, 0, 3, nullptr);
        }
        gpu::Surface front{};
        _gpuBackend->Present(front);
    }

    // Log once per second: game loop heartbeat + input state
    static int tickCount = 0;
    tickCount++;
    if (tickCount == 60) {
        LOGD("MC3 iOS Host: Game loop active (60 ticks, time=%.2f)", currentTime);

        // Poll port 0 to verify touch overlay → input routing
        input::Pad pad = input::Poll(0);
        if (pad.connected) {
            NSString* padStr = [NSString stringWithFormat:
                @"[PAD] btn=%04X A=%d B=%d X=%d Y=%d L=%d R=%d lx=%d ly=%d",
                pad.buttons,
                pad.analog[0], pad.analog[1], pad.analog[2], pad.analog[3],
                pad.analog[4], pad.analog[5],
                (int)pad.lx, (int)pad.ly];
            [MC3DebugOverlay log:padStr];
            LOGI("%s", [padStr UTF8String]);
        }

        // Show uptime + audio frame count on overlay every second
        const uint64_t audioFrames = g_audioFrames.load(std::memory_order_relaxed);
        [MC3DebugOverlay log:[NSString stringWithFormat:@"[LOOP] t=%.1fs audio=%llu",
                              currentTime, static_cast<unsigned long long>(audioFrames)]];

        tickCount = 0;
    }

    // Future: Call game->Tick(displayLink.duration) here
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];

    // Find and update Metal layer drawable size.
    // The view's own layer IS the CAMetalLayer when using MetalView.
    CAMetalLayer* metalLayer = nil;
    if ([self.view.layer isKindOfClass:[CAMetalLayer class]]) {
        metalLayer = (CAMetalLayer*)self.view.layer;
    } else {
        for (CALayer* layer in self.view.layer.sublayers) {
            if ([layer isKindOfClass:[CAMetalLayer class]]) {
                metalLayer = (CAMetalLayer*)layer;
                break;
            }
        }
    }

    if (metalLayer) {
        metalLayer.frame = self.view.bounds;
        CGSize drawableSize = self.view.bounds.size;
        drawableSize.width *= self.view.contentScaleFactor;
        drawableSize.height *= self.view.contentScaleFactor;
        metalLayer.drawableSize = drawableSize;
    }

    // Update touch overlay frame when view bounds change (e.g., rotation)
    if (self.touchControlsOverlay) {
        self.touchControlsOverlay.frame = self.view.bounds;
    }
}

- (void)dealloc {
    [self.displayLink invalidate];
    self.displayLink = nil;

    _gpuBackend.reset();
    _testState.reset();
    if (_testVbData) mem::FreeContiguous(_testVbData);
    if (_testVbHeader) mem::FreeSystem(_testVbHeader);

#if !__has_feature(objc_arc)
    [super dealloc];
#endif
}

- (BOOL)prefersStatusBarHidden {
    return YES; // Hide status bar for fullscreen game
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskLandscape; // MC3 is landscape only
}

@end
