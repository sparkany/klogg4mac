//
//  KloggBridge.mm
//  Objective-C++ implementation of the engine facade.
//
//  Drives the real klogg C++ engine (LogData / LogFilteredData) and bridges
//  Qt signals to Cocoa Foundation callbacks on the main thread.
//
//  Threading model
//  ---------------
//  Qt requires a QCoreApplication and an event loop to deliver queued-
//  connection signals between threads. We spin one up on a dedicated
//  background NSThread (gQtThread) at first KloggEngine init. LogData and
//  LogFilteredData objects are created on that thread; their worker-thread
//  signals reach the Qt event loop there and are then forwarded via
//  dispatch_async to the Cocoa main queue before invoking the
//  KloggEngineDelegate.
//
//  Signal connections use the functor/lambda overload with an explicit
//  context QObject* so that Qt can deliver the call on the Qt thread without
//  needing Q_OBJECT / MOC on any helper class we define here.
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
#include "logfiltereddata.h"
#include "abstractlogdata.h"
#include "linetypes.h"
#include "loadingstatus.h"
#include "configuration.h"
#include "persistentinfo.h"
#include "regularexpressionpattern.h"

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
    std::unique_ptr<QObject>          context;        // Qt-thread-affine context object
    std::unique_ptr<LogData>          logData;
    std::unique_ptr<LogFilteredData>  filteredData;   // created after logData
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
    // LogFilteredData must be constructed with a pointer to LogData; LogData
    // must live at least as long as the filtered data (guaranteed by layout).
    _impl->filteredData = _impl->logData->getNewFilteredData();

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

    QObject::connect(
        _impl->filteredData.get(), &LogFilteredData::searchProgressed,
        _impl->context.get(),
        [weakSelf](LinesCount nbMatches, int progress, LineNumber /*initialLine*/) {
            NSUInteger matches = static_cast<NSUInteger>(nbMatches.get());
            int pct = progress;
            dispatch_async(dispatch_get_main_queue(), ^{
                KloggEngine* e = weakSelf; if (!e) return;
                id<KloggEngineDelegate> d = e.delegate;
                if (pct >= 100) {
                    // Search complete: fire the finished callback.
                    if ([d respondsToSelector:@selector(kloggEngine:searchFinished:)])
                        [d kloggEngine:e searchFinished:matches];
                } else {
                    // Interim progress.
                    if ([d respondsToSelector:@selector(kloggEngine:searchProgressed:percent:)])
                        [d kloggEngine:e searchProgressed:matches percent:pct];
                }
            });
        },
        Qt::QueuedConnection);
}

- (void)dealloc {
    KloggEngineImpl* impl = _impl;
    _impl = nullptr;
    // Destroy on the Qt thread to keep QObject teardown on the right thread.
    if (impl) runSyncOnQtThread(^{
        // Interrupt any in-flight search before teardown.
        impl->filteredData->interruptSearch();
        delete impl;
    });
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

// MARK: - Search

- (void)searchWithPattern:(NSString*)pattern
          caseInsensitive:(BOOL)caseInsensitive
                    regex:(BOOL)isRegex {
    if (!_impl) return;

    // Build a RegularExpressionPattern.
    // isCaseSensitive = !caseInsensitive
    // isPlainText     = !isRegex   (plain-text = fixed-string search)
    // isExclude / isBoolean / isPrefilter = false for simple searches
    const bool sensitive = !static_cast<bool>(caseInsensitive);
    const bool plainText = !static_cast<bool>(isRegex);
    const QString qpat   = QString::fromNSString(pattern);
    RegularExpressionPattern regExp(qpat, sensitive, /*inverse*/false,
                                    /*boolean*/false, plainText);

    KloggEngineImpl* impl = _impl;
    QMetaObject::invokeMethod(
        impl->context.get(),
        [impl, regExp]() {
            // runSearch is synchronous up to the point of dispatching the worker;
            // searchProgressed signal drives all progress/completion callbacks.
            impl->filteredData->runSearch(regExp);
        },
        Qt::QueuedConnection);
}

// MARK: - Filtered data access (valid after searchFinished)

- (NSUInteger)searchMatchCount {
    if (!_impl) return 0;
    return static_cast<NSUInteger>(_impl->filteredData->getNbMatches().get());
}

- (NSUInteger)searchMatchLineAtIndex:(NSUInteger)matchIndex {
    if (!_impl) return NSNotFound;
    LinesCount nbMatches = _impl->filteredData->getNbMatches();
    LineNumber idx(static_cast<LineNumber::UnderlyingType>(matchIndex));
    if (!(idx < LineNumber(nbMatches.get()))) return NSNotFound;
    return static_cast<NSUInteger>(
        _impl->filteredData->getMatchingLineNumber(idx).get());
}

- (NSArray<NSString*>*)filteredLinesInRange:(NSRange)range expandTabs:(BOOL)expand {
    if (!_impl) return @[];
    LogFilteredData* fd = _impl->filteredData.get();
    LinesCount total = fd->getNbMatches();

    LineNumber::UnderlyingType first =
        static_cast<LineNumber::UnderlyingType>(range.location);
    if (LineNumber(first) >= LineNumber(total.get())) return @[];

    uint64_t available = total.get() - first;
    uint64_t requested = static_cast<uint64_t>(range.length);
    uint64_t count     = (requested < available) ? requested : available;

    klogg::vector<QString> lines =
        expand
        ? fd->getExpandedLines(LineNumber(first), LinesCount(count))
        : fd->getLines(LineNumber(first), LinesCount(count));

    NSMutableArray<NSString*>* out = [NSMutableArray arrayWithCapacity:lines.size()];
    for (const QString& qs : lines)
        [out addObject:qs.toNSString()];
    return out;
}

// MARK: - Cancel

- (void)cancel {
    if (!_impl) return;
    KloggEngineImpl* impl = _impl;
    QMetaObject::invokeMethod(
        impl->context.get(),
        [impl]() {
            impl->logData->interruptLoading();
            impl->filteredData->interruptSearch();
        },
        Qt::QueuedConnection);
}

@end
