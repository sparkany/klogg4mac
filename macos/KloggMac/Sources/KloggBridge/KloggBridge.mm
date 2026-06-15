//
//  KloggBridge.mm
//  Objective-C++ implementation of the engine facade.
//
//  Drives the real klogg C++ engine (LogData / AbstractLogData) and bridges
//  Qt signals to Cocoa Foundation callbacks on the main thread.
//
//  Threading model
//  ---------------
//  Qt requires a QCoreApplication and an event loop to deliver queued-
//  connection signals between threads. We spin one up on a dedicated
//  background NSThread (gQtThread) at first KloggEngine init. LogData
//  objects are created on that thread; their worker-thread signals reach the
//  Qt event loop there and are then forwarded via dispatch_async to the
//  Cocoa main queue before invoking the KloggEngineDelegate.
//
//  Signal connections use the functor/lambda overload with an explicit
//  context QObject* so that Qt can deliver the call on the Qt thread without
//  needing Q_OBJECT / MOC on any helper class we define here.
//
//  TODO(Phase 3): searchWithPattern -- not yet wired to LogFilteredData.
//        Returns 0 matches via delegate immediately.
//

#import "KloggBridge.h"

#include <atomic>
#include <memory>
#include <mutex>

// Qt
#include <QCoreApplication>
#include <QMetaObject>
#include <QThread>
#include <QObject>
#include <QString>

// klogg engine
#include "logdata.h"
#include "abstractlogdata.h"
#include "linetypes.h"
#include "loadingstatus.h"
#include "configuration.h"
#include "persistentinfo.h"

// PersistentInfo::ForcePortable must be defined exactly once in the app binary.
// In klogg's main.cpp it is set based on the build type; for KloggMac we
// always use the OS-standard settings location (~/Library/Preferences/…).
const bool PersistentInfo::ForcePortable = false;

// ---------------------------------------------------------------------------
// Qt application singleton -- created once per process on its own thread
// ---------------------------------------------------------------------------

static int   g_argc = 1;
static char* g_argv[] = { (char*)"KloggMac", nullptr };

static NSThread*         gQtThread = nil;
static std::once_flag    gQtStartFlag;
static std::atomic<bool> gQtReady{false};

@interface _KloggQtRunner : NSObject
@end
@implementation _KloggQtRunner
- (void)run {
    QCoreApplication app(g_argc, g_argv);
    // Initialise the Configuration singleton with defaults / saved prefs.
    // This must happen before the first LogData is constructed.
    Configuration::getSynced();
    gQtReady.store(true, std::memory_order_release);
    app.exec();   // blocks; drives the Qt event loop
}
@end

/// Ensure the Qt event-loop thread is started; blocks until exec() is running.
static void ensureQtStarted()
{
    std::call_once(gQtStartFlag, [] {
        _KloggQtRunner* runner = [_KloggQtRunner new];
        gQtThread = [[NSThread alloc] initWithTarget:runner
                                            selector:@selector(run)
                                              object:nil];
        gQtThread.name = @"KloggQtEventLoop";
        [gQtThread start];
    });
    while (!gQtReady.load(std::memory_order_acquire))
        [NSThread sleepForTimeInterval:0.001];
}

/// Run `block` synchronously on the Qt event-loop thread and wait for it.
///
/// We must NOT use performSelector:onThread:waitUntilDone: here: that relies on
/// the target thread running a Cocoa NSRunLoop, but gQtThread runs Qt's
/// QCoreApplication event loop, whose (non-GUI) event dispatcher on macOS does
/// not service Cocoa run-loop sources — so the selector would never fire and we
/// would deadlock. Instead we post the work through Qt's own event loop via
/// QMetaObject::invokeMethod (queued) and block on a semaphore until it runs.
static void runSyncOnQtThread(dispatch_block_t block)
{
    if ([NSThread currentThread] == gQtThread) { block(); return; }
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    QMetaObject::invokeMethod(qApp, [block, sem]() {
        block();
        dispatch_semaphore_signal(sem);
    }, Qt::QueuedConnection);
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
}

// ---------------------------------------------------------------------------
// Internal engine holder (C++ struct, lives on gQtThread)
// ---------------------------------------------------------------------------

struct KloggEngineImpl {
    std::unique_ptr<QObject>  context;   // context object, Qt-thread-affine
    std::unique_ptr<LogData>  logData;
};

// ---------------------------------------------------------------------------
// KloggEngine -- Objective-C class
// ---------------------------------------------------------------------------

@implementation KloggEngine {
    KloggEngineImpl* _impl;   // heap-allocated; created/destroyed on Qt thread
}

+ (BOOL)isStub { return NO; }

- (instancetype)init {
    if ((self = [super init])) {
        ensureQtStarted();
        // Create the C++ impl on the Qt thread so QObjects are affine to it.
        runSyncOnQtThread(^{ [self _createImpl]; });
    }
    return self;
}

- (void)_createImpl {
    // Runs on gQtThread.
    _impl = new KloggEngineImpl();
    _impl->context = std::make_unique<QObject>();
    _impl->logData = std::make_unique<LogData>();

    // Capture a weak reference so callbacks don't extend self's lifetime.
    __weak KloggEngine* weakSelf = self;

    QObject::connect(
        _impl->logData.get(), &LogData::loadingProgressed,
        _impl->context.get(),
        [weakSelf](int percent) {
            dispatch_async(dispatch_get_main_queue(), ^{
                KloggEngine* e = weakSelf; if (!e) return;
                if ([e.delegate respondsToSelector:@selector(kloggEngine:loadingProgress:)])
                    [e.delegate kloggEngine:e loadingProgress:percent];
            });
        },
        Qt::QueuedConnection);

    QObject::connect(
        _impl->logData.get(), &LogData::loadingFinished,
        _impl->context.get(),
        [weakSelf](LoadingStatus status) {
            BOOL ok = (status == LoadingStatus::Successful);
            dispatch_async(dispatch_get_main_queue(), ^{
                KloggEngine* e = weakSelf; if (!e) return;
                if ([e.delegate respondsToSelector:@selector(kloggEngine:loadingFinished:)])
                    [e.delegate kloggEngine:e loadingFinished:ok];
            });
        },
        Qt::QueuedConnection);
}

- (void)dealloc {
    KloggEngineImpl* impl = _impl;
    _impl = nullptr;
    // Destroy on the Qt thread to keep QObject teardown on the right thread.
    if (impl) runSyncOnQtThread(^{ delete impl; });
}

// MARK: - File open

- (void)openFileAtPath:(NSString*)path {
    if (!_impl) return;
    const QString qpath = QString::fromNSString(path);
    KloggEngineImpl* impl = _impl;
    QMetaObject::invokeMethod(
        impl->context.get(),
        [impl, qpath]() { impl->logData->attachFile(qpath); },
        Qt::QueuedConnection);
}

// MARK: - Line access (thread-safe reads via AbstractLogData)

- (NSUInteger)lineCount {
    if (!_impl) return 0;
    return static_cast<NSUInteger>(_impl->logData->getNbLine().get());
}

- (nullable NSString*)lineStringAtIndex:(NSUInteger)index {
    if (!_impl) return nil;
    LogData* ld = _impl->logData.get();
    LinesCount total = ld->getNbLine();
    LineNumber ln(static_cast<LineNumber::UnderlyingType>(index));
    if (!(ln < total)) return nil;
    return ld->getLineString(ln).toNSString();
}

- (NSArray<NSString*>*)linesInRange:(NSRange)range expandTabs:(BOOL)expand {
    if (!_impl) return @[];
    LogData* ld = _impl->logData.get();
    LinesCount total = ld->getNbLine();

    LineNumber::UnderlyingType first =
        static_cast<LineNumber::UnderlyingType>(range.location);
    if (LineNumber(first) >= total) return @[];

    uint64_t available = total.get() - first;
    uint64_t requested = static_cast<uint64_t>(range.length);
    uint64_t count     = (requested < available) ? requested : available;

    klogg::vector<QString> lines =
        expand
        ? ld->getExpandedLines(LineNumber(first), LinesCount(count))
        : ld->getLines(LineNumber(first), LinesCount(count));

    NSMutableArray<NSString*>* out = [NSMutableArray arrayWithCapacity:lines.size()];
    for (const QString& qs : lines)
        [out addObject:qs.toNSString()];
    return out;
}

// MARK: - Search (TODO Phase 3)

- (void)searchWithPattern:(NSString*)pattern
          caseInsensitive:(BOOL)caseInsensitive
                    regex:(BOOL)isRegex {
    // TODO(Phase 3): Wire LogFilteredData.  Returns 0 matches for now.
    __weak __typeof__(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        KloggEngine* s = weakSelf; if (!s) return;
        if ([s.delegate respondsToSelector:@selector(kloggEngine:searchFinished:)])
            [s.delegate kloggEngine:s searchFinished:0];
    });
}

// MARK: - Cancel

- (void)cancel {
    if (!_impl) return;
    KloggEngineImpl* impl = _impl;
    QMetaObject::invokeMethod(
        impl->context.get(),
        [impl]() { impl->logData->interruptLoading(); },
        Qt::QueuedConnection);
}

@end
