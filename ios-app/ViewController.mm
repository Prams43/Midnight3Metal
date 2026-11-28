#import "ViewController.h"
#import "app/ios_touch_controls.h"
#include "app/app.h"
#include "audio/audio.h"
#include "core/input.h"
#include "core/log.h"
#include "cpu/x86_context.h"
#include "gpu/backend.h"
#include "gpu/metal.h"
#include "kernel/kernel.h"
#include "kernel/memory.h"
#import <CommonCrypto/CommonDigest.h>
#import <QuartzCore/QuartzCore.h>
#import <QuartzCore/CAMetalLayer.h>
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstring>
#include <memory>
#include <string>
#include <vector>
#include <cstdlib>
#include <dlfcn.h>
#include <signal.h>
#include <execinfo.h>
#include <unistd.h>
#include <mach-o/dyld.h>

static std::atomic<uint64_t> g_audioFrames{0};
static NSString* const kLauncherPrefsKey = @"MC3LauncherSettings_v1";
static NSString* const kHudPrefsKey = @"MC3TouchHudConfig_v1";
static NSString* const kExpectedXbeSha1 = @"5bca1cf092edaadf876e8f80129900407a4a07b8";

// Crash reporter: writes signal, fault address (and the guest VA when it lies in guest memory),
// guest stack and host backtrace (with symbol names via dladdr) into the log file before dying.
static void MC3CrashHandler(int sig, siginfo_t* info, void*) {
    static std::atomic<int> entered{0};
    if (entered.exchange(1)) _exit(128 + sig);
    const uintptr_t addr = reinterpret_cast<uintptr_t>(info ? info->si_addr : nullptr);
    const uintptr_t base = reinterpret_cast<uintptr_t>(mem::Base());
    const uint32_t guest_va = (base && addr >= base && addr < base + 0x100000000ull) ? uint32_t(addr - base) : 0u;
    const intptr_t slide = _dyld_get_image_vmaddr_slide(0);
    LOGE("CRASH: signal=%d code=%d addr=%p guest_va=%08X base=%p slide=%p", sig, info ? info->si_code : 0,
         reinterpret_cast<void*>(addr), guest_va,
         reinterpret_cast<void*>(base), reinterpret_cast<void*>(slide));
    if (guest_va) {
        mem::RegionInfo ri{};
        const bool qok = mem::QueryVirtual(guest_va, ri);
        const mem::Stats ms = mem::Query();
        LOGE("CRASH: vm committed=%d query_ok=%d base=%08X alloc=%08X size=%08X state=%08X prot=%X | phys avail=%u/%u contig=%u sys=%u virt=%u",
             mem::IsCommitted(guest_va) ? 1 : 0, qok ? 1 : 0, ri.base, ri.alloc_base, ri.size, ri.state, ri.protect,
             ms.available_pages, ms.total_pages, ms.contiguous_used, ms.system_used, ms.virtual_committed);
    }
    if (kernel::Thread* t = kernel::Current(); t && t->ctx) {
        kernel::LogGuestStack(*t->ctx, 64);
        const uint32_t esi = t->ctx->esi;
        if (esi && mem::IsCommitted(esi) && mem::IsCommitted(esi + 0x3C)) {
            LOGE("CRASH: [esi=%08X] %08X %08X %08X %08X | +10: %08X %08X %08X %08X | +20: %08X %08X %08X %08X | +30: %08X %08X %08X %08X",
                 esi,
                 kernel::R32(esi + 0x00), kernel::R32(esi + 0x04), kernel::R32(esi + 0x08), kernel::R32(esi + 0x0C),
                 kernel::R32(esi + 0x10), kernel::R32(esi + 0x14), kernel::R32(esi + 0x18), kernel::R32(esi + 0x1C),
                 kernel::R32(esi + 0x20), kernel::R32(esi + 0x24), kernel::R32(esi + 0x28), kernel::R32(esi + 0x2C),
                 kernel::R32(esi + 0x30), kernel::R32(esi + 0x34), kernel::R32(esi + 0x38), kernel::R32(esi + 0x3C));
        }
    }
    void* frames[40];
    const int n = backtrace(frames, 40);
    for (int i = 0; i < n; i++) {
        Dl_info dli{};
        const char* sym = (dladdr(frames[i], &dli) && dli.dli_sname) ? dli.dli_sname : "?";
        const uintptr_t sym_off = dli.dli_saddr ? (reinterpret_cast<uintptr_t>(frames[i]) - reinterpret_cast<uintptr_t>(dli.dli_saddr)) : 0;
        LOGE("CRASH: frame %d %p (unslid %p) %s+0x%lx", i, frames[i],
             reinterpret_cast<void*>(reinterpret_cast<uintptr_t>(frames[i]) - slide),
             sym, static_cast<unsigned long>(sym_off));
    }
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

static NSString* ComputeFileSha1(NSString* path) {
    NSData* data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
    if (!data || data.length < 4) return nil;
    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(data.bytes, static_cast<CC_LONG>(data.length), digest);
    NSMutableString* hex = [NSMutableString stringWithCapacity:CC_SHA1_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA1_DIGEST_LENGTH; ++i) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    return hex;
}

static BOOL HasValidXbeHeader(NSString* path) {
    NSFileHandle* fh = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!fh) return NO;
    NSData* hdr = [fh readDataOfLength:4];
    [fh closeFile];
    if (hdr.length < 4) return NO;
    const uint8_t* b = static_cast<const uint8_t*>(hdr.bytes);
    return b[0] == 'X' && b[1] == 'B' && b[2] == 'E' && b[3] == 'H';
}

// UIView subclass that uses CAMetalLayer as its backing layer.
@interface MetalView : UIView
@end
@implementation MetalView
+ (Class)layerClass { return [CAMetalLayer class]; }
@end

@interface ViewController ()
@property (strong, nonatomic) UIView* touchControlsOverlay;
@property (strong, nonatomic) CADisplayLink* displayLink;
@property (nonatomic) double startTime;
@end

@implementation ViewController {
    std::unique_ptr<gpu::Backend> _gpuBackend;
    std::unique_ptr<gpu::State> _testState;
    uint32_t _testVbHeader;
    uint32_t _testVbData;
    BOOL _gameBooted;

    NSString* _docsDir;
    NSString* _detectedXbePath;
    BOOL _filesReady;

    // Pre-launch setup & settings UI
    UIView* _launcherView;
    CAGradientLayer* _launcherBgGrad;
    UIView* _leftCard;
    UIView* _rightCard;
    UIScrollView* _settingsScroll;
    UIView* _statusBadge;
    UILabel* _statusTitleLabel;
    UILabel* _statusDetailLabel;
    UIButton* _rescanButton;
    UIButton* _playButton;

    UISegmentedControl* _resSeg;
    UISegmentedControl* _filterSeg;
    UISegmentedControl* _fpsSeg;
    UISegmentedControl* _blurSeg;
    UISegmentedControl* _minimapSeg;
    UISegmentedControl* _steerSeg;
    UISwitch* _fpsCounterSwitch;
    UISwitch* _audioSwitch;
    UIButton* _resetSettingsButton;
}

+ (Class)layerClass {
    return [CAMetalLayer class];
}

- (void)loadView {
    MetalView* metalView = [[MetalView alloc] initWithFrame:[UIScreen mainScreen].bounds];
    metalView.contentScaleFactor = [UIScreen mainScreen].scale;
    self.view = metalView;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.view.backgroundColor = [UIColor colorWithRed:0.04 green:0.05 blue:0.08 alpha:1.0];
    self.startTime = CACurrentMediaTime();

    NSString* tmpDir = NSTemporaryDirectory();
    logx::Init(tmpDir ? [tmpDir UTF8String] : "/tmp", "mc3ios");
    LOGI("MC3 iOS Host: UIKit app host started");
    InstallCrashHandler();

    input::Init();
    LOGI("MC3 iOS Host: Input subsystem initialized");

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
        LOGI("[MEM] base=%p alias=%s", static_cast<void*>(base), aliasOk ? "PASS" : "FAIL");
    } else {
        LOGE("MC3 iOS Host: mem::Init failed");
    }

    audio::StartOutput([](float* out, uint32_t frames) {
        std::memset(out, 0, static_cast<size_t>(frames) * 2 * sizeof(float));
        g_audioFrames.fetch_add(frames, std::memory_order_relaxed);
    });

    CAMetalLayer* metalLayer = [self findMetalLayer];
    if (metalLayer) {
        metalLayer.contentsScale = [UIScreen mainScreen].scale;
        gpu::SetMetalLayer((__bridge void*)metalLayer);
    } else {
        LOGE("MC3 iOS Host: CAMetalLayer not found in view");
    }

    NSArray<NSString*>* docPaths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    _docsDir = docPaths.firstObject ?: tmpDir;

    setenv("MC3_SKIP_MC2_MOVIES", "1", 1);
    setenv("MC3_MC2_SAVE_PATH", [[_docsDir stringByAppendingPathComponent:@"mc2_career_progress.dat"] UTF8String], 1);

    // Build and show the English pre-launch game settings & file verification screen
    [self buildLauncherUi];
    [self loadLauncherSettings];
    [self scanGameFiles];
}

- (CAMetalLayer*)findMetalLayer {
    if ([self.view.layer isKindOfClass:[CAMetalLayer class]]) {
        return (CAMetalLayer*)self.view.layer;
    }
    for (CALayer* layer in self.view.layer.sublayers) {
        if ([layer isKindOfClass:[CAMetalLayer class]]) {
            return (CAMetalLayer*)layer;
        }
    }
    return nil;
}

#pragma mark - Pre-Launch Settings & File Verification Screen (English)

- (UILabel*)makeSectionTitle:(NSString*)text {
    UILabel* lbl = [[UILabel alloc] initWithFrame:CGRectZero];
    lbl.text = text;
    lbl.textColor = [UIColor colorWithRed:0.60 green:0.76 blue:0.90 alpha:1.0];
    lbl.font = [UIFont systemFontOfSize:11.5 weight:UIFontWeightHeavy];
    return lbl;
}

- (UISegmentedControl*)makeSegmentedControl:(NSArray<NSString*>*)items {
    UISegmentedControl* seg = [[UISegmentedControl alloc] initWithItems:items];
    seg.selectedSegmentIndex = 0;
    seg.backgroundColor = [UIColor colorWithRed:0.145 green:0.165 blue:0.208 alpha:1.0];
    if (@available(iOS 13.0, *)) {
        seg.selectedSegmentTintColor = [UIColor colorWithRed:0.26 green:0.46 blue:0.68 alpha:1.0];
    }
    [seg setTitleTextAttributes:@{
        NSForegroundColorAttributeName: [UIColor colorWithRed:0.72 green:0.76 blue:0.82 alpha:1.0],
        NSFontAttributeName: [UIFont systemFontOfSize:11.0 weight:UIFontWeightSemibold],
    } forState:UIControlStateNormal];
    [seg setTitleTextAttributes:@{
        NSForegroundColorAttributeName: [UIColor colorWithWhite:0.98 alpha:1.0],
        NSFontAttributeName: [UIFont systemFontOfSize:11.0 weight:UIFontWeightBold],
    } forState:UIControlStateSelected];
    [seg addTarget:self action:@selector(launcherSettingChanged:) forControlEvents:UIControlEventValueChanged];
    return seg;
}

- (void)buildLauncherUi {
    _launcherView = [[UIView alloc] initWithFrame:self.view.bounds];
    _launcherView.backgroundColor = [UIColor colorWithRed:0.055 green:0.064 blue:0.086 alpha:1.0];
    _launcherView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _launcherBgGrad = [CAGradientLayer layer];
    _launcherBgGrad.colors = @[
        (id)[UIColor colorWithRed:0.082 green:0.096 blue:0.128 alpha:1.0].CGColor,
        (id)[UIColor colorWithRed:0.048 green:0.056 blue:0.076 alpha:1.0].CGColor,
    ];
    _launcherBgGrad.startPoint = CGPointMake(0.2, 0.0);
    _launcherBgGrad.endPoint = CGPointMake(0.8, 1.0);
    _launcherBgGrad.frame = _launcherView.bounds;
    [_launcherView.layer insertSublayer:_launcherBgGrad atIndex:0];
    [self.view addSubview:_launcherView];

    // Left column: Branding + File Integrity Status + Play button
    _leftCard = [[UIView alloc] initWithFrame:CGRectZero];
    _leftCard.backgroundColor = [UIColor colorWithRed:0.105 green:0.120 blue:0.154 alpha:0.94];
    _leftCard.layer.cornerRadius = 18.0;
    _leftCard.layer.borderWidth = 1.0;
    _leftCard.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.12].CGColor;
    [_launcherView addSubview:_leftCard];

    UIImageView* logoView = [[UIImageView alloc] initWithFrame:CGRectZero];
    logoView.tag = 101;
    logoView.contentMode = UIViewContentModeScaleAspectFit;
    logoView.layer.cornerRadius = 14.0;
    logoView.layer.masksToBounds = YES;
    logoView.layer.borderWidth = 1.0;
    logoView.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.18].CGColor;
    NSString* logoPath = [[NSBundle mainBundle] pathForResource:@"AppIcon-180" ofType:@"png"];
    if (logoPath) {
        logoView.image = [UIImage imageWithContentsOfFile:logoPath];
    }
    [_leftCard addSubview:logoView];

    UILabel* titleLbl = [[UILabel alloc] initWithFrame:CGRectZero];
    titleLbl.tag = 102;
    titleLbl.text = @"MIDNIGHT 3 METAL";
    titleLbl.textColor = [UIColor colorWithRed:0.95 green:0.96 blue:0.98 alpha:1.0];
    titleLbl.font = [UIFont systemFontOfSize:17.5 weight:UIFontWeightBlack];
    titleLbl.adjustsFontSizeToFitWidth = YES;
    titleLbl.minimumScaleFactor = 0.75;
    [_leftCard addSubview:titleLbl];

    UILabel* subLbl = [[UILabel alloc] initWithFrame:CGRectZero];
    subLbl.tag = 103;
    subLbl.text = @"iOS Native Metal Port • v0.2 • by Prams43";
    subLbl.textColor = [UIColor colorWithRed:0.62 green:0.66 blue:0.74 alpha:1.0];
    subLbl.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightMedium];
    subLbl.adjustsFontSizeToFitWidth = YES;
    subLbl.minimumScaleFactor = 0.75;
    [_leftCard addSubview:subLbl];

    _statusBadge = [[UIView alloc] initWithFrame:CGRectZero];
    _statusBadge.backgroundColor = [UIColor colorWithRed:0.12 green:0.14 blue:0.18 alpha:1.0];
    _statusBadge.layer.cornerRadius = 13.0;
    _statusBadge.layer.borderWidth = 1.0;
    _statusBadge.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.14].CGColor;
    [_leftCard addSubview:_statusBadge];

    _statusTitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _statusTitleLabel.text = @"SCANNING GAME FILES...";
    _statusTitleLabel.textColor = [UIColor colorWithWhite:0.94 alpha:1.0];
    _statusTitleLabel.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightHeavy];
    [_statusBadge addSubview:_statusTitleLabel];

    _statusDetailLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _statusDetailLabel.text = @"Checking Documents folder...";
    _statusDetailLabel.textColor = [UIColor colorWithRed:0.78 green:0.82 blue:0.86 alpha:1.0];
    _statusDetailLabel.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightRegular];
    _statusDetailLabel.numberOfLines = 0;
    [_statusBadge addSubview:_statusDetailLabel];

    _rescanButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_rescanButton setTitle:@"RE-SCAN FILES" forState:UIControlStateNormal];
    [_rescanButton setTitleColor:[UIColor colorWithRed:0.82 green:0.89 blue:0.96 alpha:1.0] forState:UIControlStateNormal];
    _rescanButton.titleLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightBold];
    _rescanButton.backgroundColor = [UIColor colorWithRed:0.155 green:0.185 blue:0.235 alpha:0.95];
    _rescanButton.layer.cornerRadius = 11.0;
    _rescanButton.layer.borderWidth = 1.0;
    _rescanButton.layer.borderColor = [UIColor colorWithRed:0.55 green:0.70 blue:0.85 alpha:0.32].CGColor;
    [_rescanButton addTarget:self action:@selector(rescanPressed:) forControlEvents:UIControlEventTouchUpInside];
    [_leftCard addSubview:_rescanButton];

    _playButton = [UIButton buttonWithType:UIButtonTypeCustom];
    [_playButton setTitle:@"PLAY GAME" forState:UIControlStateNormal];
    [_playButton setTitleColor:[UIColor colorWithWhite:0.98 alpha:1.0] forState:UIControlStateNormal];
    [_playButton setTitleColor:[UIColor colorWithWhite:0.56 alpha:1.0] forState:UIControlStateDisabled];
    _playButton.titleLabel.font = [UIFont systemFontOfSize:15.5 weight:UIFontWeightBlack];
    _playButton.layer.cornerRadius = 12.0;
    _playButton.layer.borderWidth = 1.0;
    [_playButton addTarget:self action:@selector(playPressed:) forControlEvents:UIControlEventTouchUpInside];
    [_leftCard addSubview:_playButton];

    // Right column: Scrollable Graphics, Audio & HUD Settings
    _rightCard = [[UIView alloc] initWithFrame:CGRectZero];
    _rightCard.backgroundColor = [UIColor colorWithRed:0.105 green:0.120 blue:0.154 alpha:0.94];
    _rightCard.layer.cornerRadius = 18.0;
    _rightCard.layer.borderWidth = 1.0;
    _rightCard.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.12].CGColor;
    [_launcherView addSubview:_rightCard];

    _settingsScroll = [[UIScrollView alloc] initWithFrame:CGRectZero];
    _settingsScroll.showsVerticalScrollIndicator = YES;
    _settingsScroll.alwaysBounceVertical = YES;
    [_rightCard addSubview:_settingsScroll];

    UILabel* header = [self makeSectionTitle:@"GRAPHICS & GAME SETTINGS"];
    header.tag = 201;
    [_settingsScroll addSubview:header];

    auto addRowLabel = ^(NSInteger tag, NSString* title) {
        UILabel* l = [[UILabel alloc] initWithFrame:CGRectZero];
        l.tag = tag;
        l.text = title;
        l.textColor = [UIColor colorWithRed:0.86 green:0.89 blue:0.94 alpha:1.0];
        l.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightSemibold];
        [_settingsScroll addSubview:l];
    };

    addRowLabel(210, @"Resolution Scale");
    _resSeg = [self makeSegmentedControl:@[@"1.0x (480p)", @"1.5x (720p)", @"2.0x (960p)"]];
    [_settingsScroll addSubview:_resSeg];

    addRowLabel(211, @"Texture Filtering");
    _filterSeg = [self makeSegmentedControl:@[@"Linear", @"Anisotropic 8x"]];
    [_settingsScroll addSubview:_filterSeg];

    addRowLabel(212, @"Frame Rate Limit");
    _fpsSeg = [self makeSegmentedControl:@[@"60 FPS", @"30 FPS"]];
    [_settingsScroll addSubview:_fpsSeg];

    addRowLabel(213, @"Speed Motion Blur");
    _blurSeg = [self makeSegmentedControl:@[@"Off (Crisp)", @"Balanced"]];
    [_settingsScroll addSubview:_blurSeg];

    addRowLabel(214, @"In-Game Minimap Position");
    _minimapSeg = [self makeSegmentedControl:@[@"Default", @"Top-L", @"Top-R", @"Bot-R", @"Hidden"]];
    [_settingsScroll addSubview:_minimapSeg];

    addRowLabel(215, @"Steering Controls");
    _steerSeg = [self makeSegmentedControl:@[@"Analog Stick", @"Steer Arrows"]];
    [_settingsScroll addSubview:_steerSeg];

    addRowLabel(216, @"Show FPS Counter");
    _fpsCounterSwitch = [[UISwitch alloc] initWithFrame:CGRectZero];
    _fpsCounterSwitch.onTintColor = [UIColor colorWithRed:0.26 green:0.52 blue:0.68 alpha:1.0];
    [_fpsCounterSwitch addTarget:self action:@selector(launcherSettingChanged:) forControlEvents:UIControlEventValueChanged];
    [_settingsScroll addSubview:_fpsCounterSwitch];

    addRowLabel(217, @"Game Audio");
    _audioSwitch = [[UISwitch alloc] initWithFrame:CGRectZero];
    _audioSwitch.onTintColor = [UIColor colorWithRed:0.26 green:0.52 blue:0.68 alpha:1.0];
    [_audioSwitch addTarget:self action:@selector(launcherSettingChanged:) forControlEvents:UIControlEventValueChanged];
    [_settingsScroll addSubview:_audioSwitch];

    _resetSettingsButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_resetSettingsButton setTitle:@"RESET DEFAULT SETTINGS" forState:UIControlStateNormal];
    [_resetSettingsButton setTitleColor:[UIColor colorWithRed:0.88 green:0.60 blue:0.62 alpha:1.0] forState:UIControlStateNormal];
    _resetSettingsButton.titleLabel.font = [UIFont systemFontOfSize:11.5 weight:UIFontWeightBold];
    _resetSettingsButton.backgroundColor = [UIColor colorWithRed:0.20 green:0.13 blue:0.15 alpha:0.90];
    _resetSettingsButton.layer.cornerRadius = 11.0;
    _resetSettingsButton.layer.borderWidth = 1.0;
    _resetSettingsButton.layer.borderColor = [UIColor colorWithRed:0.74 green:0.42 blue:0.45 alpha:0.38].CGColor;
    [_resetSettingsButton addTarget:self action:@selector(resetLauncherSettings:) forControlEvents:UIControlEventTouchUpInside];
    [_settingsScroll addSubview:_resetSettingsButton];

    [self layoutLauncherUi];
}

- (void)layoutLauncherUi {
    if (!_launcherView || _launcherView.hidden) return;
    const CGRect b = self.view.bounds;
    _launcherView.frame = b;
    _launcherBgGrad.frame = b;

    UIEdgeInsets safe = UIEdgeInsetsZero;
    if (@available(iOS 11.0, *)) {
        safe = self.view.safeAreaInsets;
    }
    const CGFloat pad = 12.0;
    const CGFloat x0 = MAX(pad, safe.left + 8.0);
    const CGFloat y0 = MAX(pad, safe.top + 6.0);
    const CGFloat x1 = CGRectGetWidth(b) - MAX(pad, safe.right + 8.0);
    const CGFloat y1 = CGRectGetHeight(b) - MAX(pad, safe.bottom + 6.0);
    const CGFloat availW = MAX(320.0, x1 - x0);
    const CGFloat availH = MAX(240.0, y1 - y0);
    const CGFloat gap = 12.0;
    const CGFloat leftW = std::floor(availW * 0.43);
    const CGFloat rightW = availW - leftW - gap;

    _leftCard.frame = CGRectMake(x0, y0, leftW, availH);
    _rightCard.frame = CGRectMake(x0 + leftW + gap, y0, rightW, availH);

    // Left column layout
    const CGFloat lp = 14.0;
    const CGFloat liw = leftW - lp * 2.0;
    UIView* logo = [_leftCard viewWithTag:101];
    UIView* title = [_leftCard viewWithTag:102];
    UIView* sub = [_leftCard viewWithTag:103];
    const CGFloat logoSz = MIN(56.0, availH * 0.17);
    logo.frame = CGRectMake(lp, lp, logoSz, logoSz);
    title.frame = CGRectMake(lp + logoSz + 10.0, lp + 4.0, liw - logoSz - 10.0, 24.0);
    sub.frame = CGRectMake(lp + logoSz + 10.0, lp + 30.0, liw - logoSz - 10.0, 18.0);

    const CGFloat playH = 44.0;
    const CGFloat rescanH = 34.0;
    const CGFloat playY = availH - lp - playH;
    const CGFloat rescanY = playY - 8.0 - rescanH;
    const CGFloat badgeY = lp + logoSz + 12.0;
    const CGFloat badgeH = MAX(76.0, rescanY - 10.0 - badgeY);

    _statusBadge.frame = CGRectMake(lp, badgeY, liw, badgeH);
    _statusTitleLabel.frame = CGRectMake(12.0, 10.0, liw - 24.0, 18.0);
    _statusDetailLabel.frame = CGRectMake(12.0, 30.0, liw - 24.0, MAX(36.0, badgeH - 38.0));

    _rescanButton.frame = CGRectMake(lp, rescanY, liw, rescanH);
    _playButton.frame = CGRectMake(lp, playY, liw, playH);

    // Right column scrollable settings layout
    _settingsScroll.frame = _rightCard.bounds;
    const CGFloat rp = 14.0;
    const CGFloat riw = rightW - rp * 2.0;
    CGFloat cy = 12.0;

    [_settingsScroll viewWithTag:201].frame = CGRectMake(rp, cy, riw, 18.0);
    cy += 24.0;

    auto layoutSegRow = [&](NSInteger tag, UISegmentedControl* seg) {
        [_settingsScroll viewWithTag:tag].frame = CGRectMake(rp, cy, riw, 16.0);
        cy += 19.0;
        seg.frame = CGRectMake(rp, cy, riw, 30.0);
        cy += 38.0;
    };

    layoutSegRow(210, _resSeg);
    layoutSegRow(211, _filterSeg);
    layoutSegRow(212, _fpsSeg);
    layoutSegRow(213, _blurSeg);
    layoutSegRow(214, _minimapSeg);
    layoutSegRow(215, _steerSeg);

    auto layoutSwitchRow = [&](NSInteger tag, UISwitch* sw) {
        [_settingsScroll viewWithTag:tag].frame = CGRectMake(rp, cy + 5.0, riw - 62.0, 22.0);
        sw.center = CGPointMake(rp + riw - 28.0, cy + 16.0);
        cy += 38.0;
    };

    layoutSwitchRow(216, _fpsCounterSwitch);
    layoutSwitchRow(217, _audioSwitch);

    cy += 4.0;
    _resetSettingsButton.frame = CGRectMake(rp, cy, riw, 34.0);
    cy += 48.0;

    _settingsScroll.contentSize = CGSizeMake(rightW, cy);
}

- (void)loadLauncherSettings {
    NSDictionary* cfg = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kLauncherPrefsKey];
    NSDictionary* hudCfg = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kHudPrefsKey];

    NSInteger resIdx = 0;
    NSInteger filterIdx = 1;  // Anisotropic 8x default
    NSInteger fpsIdx = 0;     // 60 FPS default
    NSInteger blurIdx = 0;    // Off (Crisp) default
    NSInteger minimapIdx = 0; // Default Xbox bottom-left
    NSInteger steerIdx = 0;   // Analog Stick default
    BOOL showFps = YES;
    BOOL audioOn = YES;

    if ([cfg isKindOfClass:[NSDictionary class]]) {
        if ([cfg[@"resIdx"] isKindOfClass:[NSNumber class]]) resIdx = [cfg[@"resIdx"] integerValue];
        if ([cfg[@"filterIdx"] isKindOfClass:[NSNumber class]]) filterIdx = [cfg[@"filterIdx"] integerValue];
        if ([cfg[@"fpsIdx"] isKindOfClass:[NSNumber class]]) fpsIdx = [cfg[@"fpsIdx"] integerValue];
        if ([cfg[@"blurIdx"] isKindOfClass:[NSNumber class]]) blurIdx = [cfg[@"blurIdx"] integerValue];
        if ([cfg[@"minimapIdx"] isKindOfClass:[NSNumber class]]) minimapIdx = [cfg[@"minimapIdx"] integerValue];
        if ([cfg[@"audioOn"] isKindOfClass:[NSNumber class]]) audioOn = [cfg[@"audioOn"] boolValue];
    }
    if ([hudCfg isKindOfClass:[NSDictionary class]]) {
        if ([hudCfg[@"arrowSteering"] isKindOfClass:[NSNumber class]]) {
            steerIdx = [hudCfg[@"arrowSteering"] boolValue] ? 1 : 0;
        }
        if ([hudCfg[@"showFps"] isKindOfClass:[NSNumber class]]) {
            showFps = [hudCfg[@"showFps"] boolValue];
        }
    }

    _resSeg.selectedSegmentIndex = std::clamp<NSInteger>(resIdx, 0, 2);
    _filterSeg.selectedSegmentIndex = std::clamp<NSInteger>(filterIdx, 0, 1);
    _fpsSeg.selectedSegmentIndex = std::clamp<NSInteger>(fpsIdx, 0, 1);
    _blurSeg.selectedSegmentIndex = std::clamp<NSInteger>(blurIdx, 0, 1);
    _minimapSeg.selectedSegmentIndex = std::clamp<NSInteger>(minimapIdx, 0, 4);
    _steerSeg.selectedSegmentIndex = std::clamp<NSInteger>(steerIdx, 0, 1);
    _fpsCounterSwitch.on = showFps;
    _audioSwitch.on = audioOn;

    [self applyAndSaveLauncherSettings];
}

- (void)applyAndSaveLauncherSettings {
    const float resScales[3] = {1.0f, 1.5f, 2.0f};
    const NSInteger resIdx = std::clamp<NSInteger>(_resSeg.selectedSegmentIndex, 0, 2);
    gpu::SetResolutionScale(resScales[resIdx]);
    gpu::SetAnisotropicFiltering(_filterSeg.selectedSegmentIndex == 1);
    gpu::SetTargetFps(_fpsSeg.selectedSegmentIndex == 1 ? 30u : 60u);
    gpu::SetMotionBlurEnabled(_blurSeg.selectedSegmentIndex == 1);
    audio::SetMuted(!_audioSwitch.on);

    gpu::MinimapConfig mm{};
    switch (_minimapSeg.selectedSegmentIndex) {
    case 1: mm = {true, true, 0.16f, 0.29f}; break;   // Top-Left (below top bar, inset from left)
    case 2: mm = {true, true, 0.85f, 0.29f}; break;   // Top-Right
    case 3: mm = {true, true, 0.85f, 0.78f}; break;   // Bottom-Right
    case 4: mm = {false, false, 0.14f, 0.78f}; break; // Hidden
    case 0:
    default: mm = {true, false, 0.14f, 0.78f}; break; // Default bottom-left
    }
    gpu::SetMinimapConfig(mm);

    NSDictionary* cfg = @{
        @"resIdx": @(_resSeg.selectedSegmentIndex),
        @"filterIdx": @(_filterSeg.selectedSegmentIndex),
        @"fpsIdx": @(_fpsSeg.selectedSegmentIndex),
        @"blurIdx": @(_blurSeg.selectedSegmentIndex),
        @"minimapIdx": @(_minimapSeg.selectedSegmentIndex),
        @"audioOn": @(_audioSwitch.on),
    };
    [[NSUserDefaults standardUserDefaults] setObject:cfg forKey:kLauncherPrefsKey];

    // Sync HUD preferences (steering style, FPS visibility, and minimap config) with ios_touch_controls
    NSDictionary* existingHud = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kHudPrefsKey];
    NSMutableDictionary* mergedHud = existingHud ? [existingHud mutableCopy] : [NSMutableDictionary dictionary];
    mergedHud[@"arrowSteering"] = @(_steerSeg.selectedSegmentIndex == 1);
    mergedHud[@"showFps"] = @(_fpsCounterSwitch.on);
    mergedHud[@"minimapVisible"] = @(mm.visible);
    mergedHud[@"minimapCustom"] = @(mm.custom);
    mergedHud[@"minimapX"] = @(mm.norm_x);
    mergedHud[@"minimapY"] = @(mm.norm_y);
    [[NSUserDefaults standardUserDefaults] setObject:mergedHud forKey:kHudPrefsKey];
}

- (void)launcherSettingChanged:(id)sender {
    (void)sender;
    [self applyAndSaveLauncherSettings];
}

- (void)resetLauncherSettings:(UIButton*)sender {
    (void)sender;
    _resSeg.selectedSegmentIndex = 0;
    _filterSeg.selectedSegmentIndex = 1;
    _fpsSeg.selectedSegmentIndex = 0;
    _blurSeg.selectedSegmentIndex = 0;
    _minimapSeg.selectedSegmentIndex = 0;
    _steerSeg.selectedSegmentIndex = 0;
    _fpsCounterSwitch.on = YES;
    _audioSwitch.on = YES;
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:kHudPrefsKey];
    [self applyAndSaveLauncherSettings];
}

- (void)scanGameFiles {
    NSFileManager* fm = [NSFileManager defaultManager];

    // Locate default.xbe (case-insensitive in Documents, or fallback in bundle)
    NSString* xbePath = nil;
    NSArray<NSString*>* topItems = [fm contentsOfDirectoryAtPath:_docsDir error:nil] ?: @[];
    for (NSString* name in topItems) {
        if ([name.lowercaseString isEqualToString:@"default.xbe"]) {
            xbePath = [_docsDir stringByAppendingPathComponent:name];
            break;
        }
    }
    if (!xbePath) {
        NSString* inBundle = [[NSBundle mainBundle] pathForResource:@"default" ofType:@"xbe"];
        if (inBundle && [fm fileExistsAtPath:inBundle]) xbePath = inBundle;
    }

    const BOOL xbeFound = (xbePath != nil);
    const BOOL xbeHeaderOk = xbeFound && HasValidXbeHeader(xbePath);
    NSString* sha1 = xbeHeaderOk ? ComputeFileSha1(xbePath) : nil;
    const BOOL xbeVerified = (sha1 != nil && [sha1.lowercaseString isEqualToString:kExpectedXbeSha1]);

    // Check for game asset archive (assets_x.dat) or extracted game folders
    BOOL hasArchive = NO;
    uint64_t assetBytes = 0;
    for (NSString* name in topItems) {
        NSString* low = name.lowercaseString;
        if ([low isEqualToString:@"save"] || [low hasPrefix:@"mc2_career"] || [low hasPrefix:@"."]) continue;
        NSString* full = [_docsDir stringByAppendingPathComponent:name];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:full isDirectory:&isDir]) continue;
        if ([low isEqualToString:@"assets_x.dat"] || [low hasPrefix:@"assets_x.dat"]) {
            hasArchive = YES;
        }
        if (!isDir) {
            NSDictionary* attrs = [fm attributesOfItemAtPath:full error:nil];
            assetBytes += [attrs fileSize];
        } else {
            NSDirectoryEnumerator* en = [fm enumeratorAtPath:full];
            NSString* rel = nil;
            int counted = 0;
            while ((rel = [en nextObject]) != nil && counted++ < 2000) {
                NSDictionary* attrs = [en fileAttributes];
                if ([[attrs fileType] isEqualToString:NSFileTypeRegular]) {
                    assetBytes += [attrs fileSize];
                }
            }
        }
    }

    const BOOL assetsFound = hasArchive || (assetBytes >= 50ull * 1024ull * 1024ull);
    const double assetGb = double(assetBytes) / (1024.0 * 1024.0 * 1024.0);

    _detectedXbePath = xbeHeaderOk ? xbePath : nil;
    _filesReady = (xbeHeaderOk && assetsFound);

    if (_filesReady) {
        _statusBadge.backgroundColor = [UIColor colorWithRed:0.105 green:0.185 blue:0.168 alpha:0.92];
        _statusBadge.layer.borderColor = [UIColor colorWithRed:0.36 green:0.66 blue:0.55 alpha:0.52].CGColor;
        _statusTitleLabel.text = @"● GAME FILES DETECTED";
        _statusTitleLabel.textColor = [UIColor colorWithRed:0.56 green:0.85 blue:0.72 alpha:1.0];
        _statusDetailLabel.text = [NSString stringWithFormat:
            @"Executable: default.xbe (%@)\nGame Assets: Detected (%.2f GB)\nStatus: Ready to launch.",
            xbeVerified ? @"Verified Retail" : @"Valid XBE",
            assetGb];

        _playButton.enabled = YES;
        [_playButton setTitle:@"PLAY GAME" forState:UIControlStateNormal];
        _playButton.backgroundColor = [UIColor colorWithRed:0.20 green:0.50 blue:0.42 alpha:1.0];
        _playButton.layer.borderColor = [UIColor colorWithRed:0.48 green:0.80 blue:0.70 alpha:0.52].CGColor;
    } else if (xbeHeaderOk && !assetsFound) {
        _statusBadge.backgroundColor = [UIColor colorWithRed:0.21 green:0.17 blue:0.11 alpha:0.92];
        _statusBadge.layer.borderColor = [UIColor colorWithRed:0.76 green:0.58 blue:0.30 alpha:0.52].CGColor;
        _statusTitleLabel.text = @"▲ GAME ASSETS NOT DETECTED";
        _statusTitleLabel.textColor = [UIColor colorWithRed:0.90 green:0.77 blue:0.48 alpha:1.0];
        _statusDetailLabel.text =
            @"default.xbe was found, but game asset files (assets_x.dat / folders) are missing.\n"
            @"Copy all extracted Xbox game files into:\nFiles → On My iPhone → MC3 Remix";

        _playButton.enabled = NO;
        [_playButton setTitle:@"GAME FILES REQUIRED" forState:UIControlStateDisabled];
        _playButton.backgroundColor = [UIColor colorWithRed:0.15 green:0.17 blue:0.21 alpha:1.0];
        _playButton.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.12].CGColor;
    } else {
        _statusBadge.backgroundColor = [UIColor colorWithRed:0.21 green:0.12 blue:0.13 alpha:0.92];
        _statusBadge.layer.borderColor = [UIColor colorWithRed:0.76 green:0.39 blue:0.42 alpha:0.52].CGColor;
        _statusTitleLabel.text = @"✕ GAME FILES NOT DETECTED";
        _statusTitleLabel.textColor = [UIColor colorWithRed:0.92 green:0.59 blue:0.61 alpha:1.0];
        _statusDetailLabel.text = xbeFound
            ? @"default.xbe is invalid or corrupted.\nReplace it with a valid Xbox copy in:\nFiles → On My iPhone → MC3 Remix"
            : @"No Xbox game files found.\nCopy default.xbe and game folders into:\nFiles → On My iPhone → MC3 Remix";

        _playButton.enabled = NO;
        [_playButton setTitle:@"GAME FILES NOT DETECTED" forState:UIControlStateDisabled];
        _playButton.backgroundColor = [UIColor colorWithRed:0.15 green:0.17 blue:0.21 alpha:1.0];
        _playButton.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.12].CGColor;
    }
}

- (void)rescanPressed:(UIButton*)sender {
    (void)sender;
    [self scanGameFiles];
}

- (void)playPressed:(UIButton*)sender {
    (void)sender;
    if (!_filesReady || !_detectedXbePath || _gameBooted) return;
    [self applyAndSaveLauncherSettings];
    _playButton.enabled = NO;
    [_playButton setTitle:@"LAUNCHING..." forState:UIControlStateDisabled];

    NSData* raw = [NSData dataWithContentsOfFile:_detectedXbePath];
    if (!raw || raw.length == 0) {
        [self scanGameFiles];
        return;
    }

    std::vector<uint8_t> xbeBytes(static_cast<const uint8_t*>(raw.bytes),
                                  static_cast<const uint8_t*>(raw.bytes) + raw.length);
    std::string gameDir = [_docsDir UTF8String];
    std::string dataDir = [[_docsDir stringByAppendingPathComponent:@"save"] UTF8String];
    [[NSFileManager defaultManager] createDirectoryAtPath:[_docsDir stringByAppendingPathComponent:@"save"]
                              withIntermediateDirectories:YES attributes:nil error:nil];

    if (app::kGame.init) app::kGame.init();
    const bool booted = kernel::Boot(std::move(xbeBytes), "default.xbe", gameDir, dataDir);
    _gameBooted = booted ? YES : NO;
    LOGI("[BOOT] default.xbe -> %s (ep=0x%08X)", booted ? "OK" : "FAILED", X86EntryPoint);

    if (!_gameBooted) {
        [self scanGameFiles];
        return;
    }

    // Create touch controls overlay (with glossy icons + HUD & Minimap editor)
    self.touchControlsOverlay = app::CreateTouchControlsOverlay(self.view.bounds);
    if (self.touchControlsOverlay) {
        self.touchControlsOverlay.alpha = 0.0;
        [self.view addSubview:self.touchControlsOverlay];
    }

    [UIView animateWithDuration:0.22 animations:^{
        _launcherView.alpha = 0.0;
        self.touchControlsOverlay.alpha = 1.0;
    } completion:^(BOOL finished) {
        (void)finished;
        [_launcherView removeFromSuperview];
        _launcherView = nil;
    }];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];

    CAMetalLayer* metalLayer = [self findMetalLayer];
    if (metalLayer) {
        metalLayer.frame = self.view.bounds;
        CGSize drawableSize = self.view.bounds.size;
        drawableSize.width *= self.view.contentScaleFactor;
        drawableSize.height *= self.view.contentScaleFactor;
        metalLayer.drawableSize = drawableSize;
    }

    if (_launcherView && !_launcherView.hidden) {
        [self layoutLauncherUi];
    }
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
    return YES;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskLandscape;
}

@end
