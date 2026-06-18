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
#include <vector>

// Qt
#include <QCoreApplication>
#include <QMetaObject>
#include <QThread>
#include <QObject>
#include <QString>
#include <QRegularExpression>
#include <QTextCodec>

// klogg engine
#include "logdata.h"
#include "logfiltereddata.h"
#include "abstractlogdata.h"
#include "linetypes.h"
#include "loadingstatus.h"
#include "configuration.h"
#include "persistentinfo.h"
#include "regularexpressionpattern.h"
#include "filewatcher.h"

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
    bool                              attached = false; // a file has been attachFile'd
    // User-forced encoding MIB (from the Encoding menu). < 0 means "auto-detect": after
    // indexing finishes we apply the uchardet guess. >= 0 means the user pinned a codec,
    // which we re-apply after each (re)index so the chosen encoding survives reloads.
    int                               forcedMib = -1;

    // Apply the effective display codec after indexing finishes. LogData decodes lines
    // lazily through codec_ (default ISO-8859-1); without this, a UTF-8 file with CJK or
    // emoji is decoded as Latin-1 and shows up as mojibake. MUST run on the Qt thread.
    void applyDisplayEncoding() {
        QTextCodec* codec = nullptr;
        if ( forcedMib >= 0 ) {
            codec = QTextCodec::codecForMib( forcedMib );
        }
        if ( !codec ) {
            codec = logData->getDetectedEncoding();  // uchardet guess from indexing
        }
        if ( codec ) {
            logData->setDisplayEncoding( codec->name().constData() );
        }
    }

    // --- Search-result SNAPSHOT (race-free read path) ---------------------------
    // LogFilteredData's result set (matching_lines_ / marks_and_matches_) is a CRoaring
    // bitmap that the engine MUTATES on the Qt thread in handleSearchProgressed
    // (matching_lines_ |= newMatches) while a search runs. CRoaring bitmaps are not
    // thread-safe, so the UI/main thread must NEVER read the live LogFilteredData. Instead
    // we keep a plain, bridge-owned snapshot: every time the search progresses/finishes,
    // we copy (on the Qt thread, where CRoaring access is safe) the match count and the
    // matched source-line numbers into snapMatchLines_. The main-thread read accessors
    // (searchMatchCount / searchMatchLineAtIndex / filteredLinesInRange) lock snapMutex_
    // and read ONLY this immutable copy — they never touch the live bitmap. This removes
    // the data race without marshalling each read onto the Qt thread (which stalls the UI
    // and can deadlock against the search worker's QThreadPool::waitForDone()).
    std::mutex                        snapMutex;
    std::vector<uint64_t>             snapMatchLines; // source-line index per match, in order
    uint64_t                          snapMatchCount = 0;

    // Rebuild the snapshot from the live filtered data. MUST be called on the Qt thread.
    void rebuildSearchSnapshot() {
        std::vector<uint64_t> lines;
        const uint64_t count =
            static_cast<uint64_t>(filteredData->getNbMatches().get());
        lines.reserve(static_cast<size_t>(count));
        for (uint64_t i = 0; i < count; ++i) {
            const LineNumber src = filteredData->getMatchingLineNumber(
                LineNumber(static_cast<LineNumber::UnderlyingType>(i)));
            lines.push_back(static_cast<uint64_t>(src.get()));
        }
        std::lock_guard<std::mutex> guard(snapMutex);
        snapMatchCount = count;
        snapMatchLines = std::move(lines);
    }

    void clearSearchSnapshot() {
        std::lock_guard<std::mutex> guard(snapMutex);
        snapMatchCount = 0;
        snapMatchLines.clear();
    }
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
            // Runs on the Qt thread. Apply the detected (or user-forced) display codec
            // BEFORE notifying the delegate, so the view's first fetch decodes correctly.
            if (ok) {
                KloggEngine* e = weakSelf;
                if (e && e->_impl) e->_impl->applyDisplayEncoding();
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                KloggEngine* e = weakSelf; if (!e) return;
                if ([e.delegate respondsToSelector:@selector(kloggEngine:loadingFinished:)])
                    [e.delegate kloggEngine:e loadingFinished:ok];
            });
        },
        Qt::QueuedConnection);

    {
        KloggEngineImpl* impl = _impl;   // owned by self; valid while connection lives
        QObject::connect(
            _impl->filteredData.get(), &LogFilteredData::searchProgressed,
            _impl->context.get(),
            [weakSelf, impl](LinesCount nbMatches, int progress, LineNumber /*initialLine*/) {
            // Runs on the Qt thread. Refresh the race-free snapshot HERE — this is the only
            // place we read the live CRoaring result set, and it is the same thread that
            // mutates it, so the access is safe and serialized with handleSearchProgressed.
            impl->rebuildSearchSnapshot();

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

    // File-on-disk changes (follow / file-watch). The engine has already enqueued a
    // re-index by the time this fires; loadingFinished follows. We forward the status
    // so the UI can auto-scroll to the new tail when following.
    QObject::connect(
        _impl->logData.get(), &LogData::fileChanged,
        _impl->context.get(),
        [weakSelf](MonitoredFileStatus status) {
            NSInteger code = static_cast<NSInteger>(status);
            dispatch_async(dispatch_get_main_queue(), ^{
                KloggEngine* e = weakSelf; if (!e) return;
                if ([e.delegate respondsToSelector:@selector(kloggEngine:fileChanged:)])
                    [e.delegate kloggEngine:e fileChanged:code];
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
    KloggEngineImpl* impl = _impl;
    // attachFile is one-shot per LogData (re-attaching throws CantReattachErr); if
    // the same path is opened again, treat it as a reload of the live file.
    if (impl->attached) { [self reload]; return; }
    const QString qpath = QString::fromNSString(path);
    impl->attached = true;
    QMetaObject::invokeMethod(
        impl->context.get(),
        [impl, qpath]() { impl->logData->attachFile(qpath); },
        Qt::QueuedConnection);
}

- (void)reload {
    if (!_impl) return;
    KloggEngineImpl* impl = _impl;
    if (!impl->attached) return;   // nothing attached yet
    QMetaObject::invokeMethod(
        impl->context.get(),
        [impl]() { impl->logData->reload(); },
        Qt::QueuedConnection);
}

- (void)reloadWithEncodingMib:(NSInteger)mib {
    if (!_impl) return;
    KloggEngineImpl* impl = _impl;
    if (!impl->attached) return;   // nothing attached yet
    const int mibValue = static_cast<int>(mib);
    QMetaObject::invokeMethod(
        impl->context.get(),
        [impl, mibValue]() {
            // mib < 0 → auto-detect (forcedEncoding == nullptr). Otherwise look up the
            // codec by MIB; if it is unknown, fall back to auto-detect rather than crash.
            QTextCodec* codec = (mibValue >= 0) ? QTextCodec::codecForMib(mibValue) : nullptr;
            // Remember the user's choice so applyDisplayEncoding (run on loadingFinished)
            // pins this codec; if codecForMib didn't resolve, treat it as auto-detect.
            impl->forcedMib = codec ? mibValue : -1;
            impl->logData->reload(codec);
        },
        Qt::QueuedConnection);
}

- (void)setFollowEnabled:(BOOL)enabled {
    // The engine already adds the attached file to the global FileWatcher when its
    // indexing finishes, and re-indexes on change. To make growth detection reliable
    // (independent of native FS-event delivery, which is flaky under a non-GUI Qt
    // event loop / sandbox), turn on polling at a short interval while following.
    runSyncOnQtThread(^{
        Configuration& config = Configuration::get();
        if (enabled) {
            config.setPollingEnabled(true);
            if (config.pollIntervalMs() > 500)
                config.setPollIntervalMs(500);
        }
        // Native watch stays at its configured default; we only drive polling here so
        // we never disable a watch another tab may rely on.
        FileWatcher::getFileWatcher().updateConfiguration();
    });
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
    // Convenience: simple search, not inverted, not boolean, over the whole file.
    [self searchWithPattern:pattern
            caseInsensitive:caseInsensitive
                      regex:isRegex
                    inverse:NO
                    boolean:NO
                  startLine:0
                    endLine:NSUIntegerMax];
}

/// Construct the RegularExpressionPattern mirroring klogg's replaceCurrentSearch:
///   RegularExpressionPattern( searchText, matchCaseButton_->isChecked(),
///       inverseButton_->isChecked(), booleanButton_->isChecked(),
///       !useRegexpButton_->isChecked() )
/// i.e. ctor arg order is (expression, isCaseSensitive, inverse, boolean, plainText).
static RegularExpressionPattern makePattern(NSString* pattern, BOOL caseInsensitive,
                                            BOOL isRegex, BOOL inverse, BOOL boolean) {
    const bool sensitive = !static_cast<bool>(caseInsensitive);
    const bool plainText = !static_cast<bool>(isRegex);
    const QString qpat   = QString::fromNSString(pattern);
    return RegularExpressionPattern(qpat, sensitive, static_cast<bool>(inverse),
                                    static_cast<bool>(boolean), plainText);
}

- (void)searchWithPattern:(NSString*)pattern
          caseInsensitive:(BOOL)caseInsensitive
                    regex:(BOOL)isRegex
                  inverse:(BOOL)inverse
                  boolean:(BOOL)boolean
                startLine:(NSUInteger)startLine
                  endLine:(NSUInteger)endLine {
    if (!_impl) return;

    RegularExpressionPattern regExp =
        makePattern(pattern, caseInsensitive, isRegex, inverse, boolean);

    KloggEngineImpl* impl = _impl;
    const NSUInteger start = startLine;
    const NSUInteger end   = endLine;
    QMetaObject::invokeMethod(
        impl->context.get(),
        [impl, regExp, start, end]() {
            // Invalidate the snapshot as the new search begins (the engine clears its
            // result set inside runSearch); the first searchProgressed will refill it.
            // Done here on the Qt thread so reads never see the previous search's results.
            impl->clearSearchSnapshot();
            // Clamp the range to the file: end == NSUIntegerMax (or beyond EOF) means
            // "to end of file"; an empty/invalid range degenerates to a whole-file search
            // so the UI never silently returns nothing for a bad limit.
            const uint64_t total = impl->logData->getNbLine().get();
            uint64_t s = static_cast<uint64_t>(start);
            uint64_t e = (end == static_cast<NSUInteger>(NSUIntegerMax))
                             ? total
                             : static_cast<uint64_t>(end);
            if (e > total) e = total;
            if (s > total) s = total;
            // runSearch is synchronous up to the point of dispatching the worker;
            // searchProgressed signal drives all progress/completion callbacks.
            if (s == 0 && e == total) {
                impl->filteredData->runSearch(regExp);
            } else {
                impl->filteredData->runSearch(
                    regExp,
                    LineNumber(static_cast<LineNumber::UnderlyingType>(s)),
                    LineNumber(static_cast<LineNumber::UnderlyingType>(e)));
            }
        },
        Qt::QueuedConnection);
}

- (BOOL)isValidSearchPattern:(NSString*)pattern
                       regex:(BOOL)isRegex
                     boolean:(BOOL)boolean {
    // An empty pattern is "valid" in the sense klogg treats it (clears the search).
    if (pattern.length == 0) return YES;

    // We validate with Qt's QRegularExpression rather than constructing the engine's
    // full RegularExpression: the latter compiles a Hyperscan database, which is unsafe
    // to build on the Qt thread while a runSearch may be dispatching (it shares the same
    // worker machinery) and is far heavier than a validity check needs. QRegularExpression
    // gives the same syntax verdict for the regex grammar klogg uses.
    const QString qpat = QString::fromNSString(pattern);

    if (boolean) {
        // Boolean mode (klogg parseBooleanExpressions): sub-patterns MUST be enclosed in
        // quotes ("foo" and not("bar")) — klogg throws otherwise. Mirror that rule and
        // validate every quoted sub-pattern as a regex. The boolean grammar itself
        // (and/or/not/parentheses) is checked structurally by the engine; we catch the
        // common syntax errors (no quotes / unbalanced quotes / bad sub-regex) cheaply.
        if (!qpat.contains(QLatin1Char('"'))) return NO;   // klogg: "Patterns must be enclosed in quotes"
        int quoteCount = 0;
        QString current;
        bool inQuote = false;
        bool ok = true;
        for (int i = 0; i < qpat.length(); ++i) {
            const QChar c = qpat.at(i);
            if (c == QLatin1Char('"')) {
                quoteCount++;
                if (inQuote) {
                    QRegularExpression sub(current);
                    if (!sub.isValid()) { ok = false; break; }
                    current.clear();
                }
                inQuote = !inQuote;
            } else if (inQuote) {
                current.append(c);
            }
        }
        if ((quoteCount % 2) != 0) ok = false;   // unbalanced quotes
        return ok ? YES : NO;
    }

    if (!isRegex) {
        // Plain text: always a valid fixed-string search.
        return YES;
    }

    QRegularExpression re(qpat);
    return re.isValid() ? YES : NO;
}

// MARK: - Filtered data access (valid after searchFinished)

// All three accessors read ONLY the bridge-owned snapshot (see KloggEngineImpl), never
// the live LogFilteredData/CRoaring bitmap, so they are safe to call from the main thread
// while a search mutates the engine on the Qt thread.

- (NSUInteger)searchMatchCount {
    if (!_impl) return 0;
    std::lock_guard<std::mutex> guard(_impl->snapMutex);
    return static_cast<NSUInteger>(_impl->snapMatchCount);
}

- (NSUInteger)searchMatchLineAtIndex:(NSUInteger)matchIndex {
    if (!_impl) return NSNotFound;
    std::lock_guard<std::mutex> guard(_impl->snapMutex);
    if (matchIndex >= _impl->snapMatchLines.size()) return NSNotFound;
    return static_cast<NSUInteger>(_impl->snapMatchLines[matchIndex]);
}

- (NSArray<NSString*>*)filteredLinesInRange:(NSRange)range expandTabs:(BOOL)expand {
    if (!_impl) return @[];

    // Resolve the requested filtered rows to SOURCE line numbers from the snapshot
    // (lock briefly, copy out), then read the line TEXT from LogData — whose reads are
    // internally serialized (IndexingData accessor lock + FileHolder file mutex) and so
    // are safe from the main thread. We never touch the CRoaring result set here.
    std::vector<uint64_t> srcLines;
    {
        std::lock_guard<std::mutex> guard(_impl->snapMutex);
        const uint64_t total = _impl->snapMatchCount;
        uint64_t first = static_cast<uint64_t>(range.location);
        if (first >= total) return @[];
        uint64_t available = total - first;
        uint64_t requested = static_cast<uint64_t>(range.length);
        uint64_t count     = (requested < available) ? requested : available;
        srcLines.reserve(static_cast<size_t>(count));
        for (uint64_t i = 0; i < count && (first + i) < _impl->snapMatchLines.size(); ++i)
            srcLines.push_back(_impl->snapMatchLines[static_cast<size_t>(first + i)]);
    }

    LogData* ld = _impl->logData.get();
    NSMutableArray<NSString*>* out = [NSMutableArray arrayWithCapacity:srcLines.size()];
    for (uint64_t src : srcLines) {
        LineNumber ln(static_cast<LineNumber::UnderlyingType>(src));
        const QString qs = expand ? ld->getExpandedLineString(ln) : ld->getLineString(ln);
        [out addObject:qs.toNSString()];
    }
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

// MARK: - KloggDecompressor

#include <zlib.h>
#include <bzlib.h>
#include <lzma.h>

namespace {

constexpr size_t kDecompChunk = 4 * 1024 * 1024;  // 4 MiB, matches decompressor.cpp

// Detect a single-stream compression format by extension, mirroring
// archiveTypeByExtension() in src/ui/src/decompressor.cpp (Gz/Bz2/Xz only — tar.*
// and zip/7z need KArchive, which we deliberately don't support here).
enum class CompFormat { None, Gz, Bz2, Xz };

CompFormat formatForPath(NSString* path)
{
    NSString* lower = path.lowercaseString;
    // Exclude multi-file tar archives (tar.gz / tgz / tbz2 / txz …).
    if ([lower hasSuffix:@".tar.gz"] || [lower hasSuffix:@".tgz"]
        || [lower hasSuffix:@".tar.bz2"] || [lower hasSuffix:@".tbz2"] || [lower hasSuffix:@".tbz"]
        || [lower hasSuffix:@".tar.xz"] || [lower hasSuffix:@".txz"]
        || [lower hasSuffix:@".tar.lzma"]) {
        return CompFormat::None;
    }
    if ([lower hasSuffix:@".gz"])   return CompFormat::Gz;
    if ([lower hasSuffix:@".bz2"])  return CompFormat::Bz2;
    if ([lower hasSuffix:@".xz"] || [lower hasSuffix:@".lzma"]) return CompFormat::Xz;
    return CompFormat::None;
}

NSError* makeError(NSString* msg)
{
    return [NSError errorWithDomain:@"KloggDecompressor"
                               code:1
                           userInfo:@{ NSLocalizedDescriptionKey: msg }];
}

// gzip → out fd, using zlib's gz* helpers (handles the gzip container directly).
bool decompressGz(NSString* path, int outFd, NSError** error)
{
    gzFile in = gzopen(path.fileSystemRepresentation, "rb");
    if (!in) { if (error) *error = makeError(@"gzopen failed"); return false; }
    std::vector<char> buf(kDecompChunk);
    bool ok = true;
    for (;;) {
        int n = gzread(in, buf.data(), (unsigned)buf.size());
        if (n < 0)  { ok = false; if (error) *error = makeError(@"gzread error"); break; }
        if (n == 0) break;  // EOF
        if (write(outFd, buf.data(), (size_t)n) != n) {
            ok = false; if (error) *error = makeError(@"write error"); break;
        }
    }
    gzclose(in);
    return ok;
}

// bzip2 → out fd, via BZ2_bzRead on a stdio FILE*.
bool decompressBz2(NSString* path, int outFd, NSError** error)
{
    FILE* f = fopen(path.fileSystemRepresentation, "rb");
    if (!f) { if (error) *error = makeError(@"fopen failed"); return false; }
    int bzerr = BZ_OK;
    BZFILE* bz = BZ2_bzReadOpen(&bzerr, f, 0, 0, nullptr, 0);
    if (bzerr != BZ_OK) { fclose(f); if (error) *error = makeError(@"BZ2_bzReadOpen failed"); return false; }
    std::vector<char> buf(kDecompChunk);
    bool ok = true;
    for (;;) {
        int n = BZ2_bzRead(&bzerr, bz, buf.data(), (int)buf.size());
        if (n > 0) {
            if (write(outFd, buf.data(), (size_t)n) != n) {
                ok = false; if (error) *error = makeError(@"write error"); break;
            }
        }
        if (bzerr == BZ_STREAM_END) break;
        if (bzerr != BZ_OK) { ok = false; if (error) *error = makeError(@"BZ2_bzRead error"); break; }
    }
    int closeErr = BZ_OK;
    BZ2_bzReadClose(&closeErr, bz);
    fclose(f);
    return ok;
}

// xz / lzma → out fd, using liblzma's auto-decoder (handles both .xz and legacy .lzma).
bool decompressXz(NSString* path, int outFd, NSError** error)
{
    FILE* f = fopen(path.fileSystemRepresentation, "rb");
    if (!f) { if (error) *error = makeError(@"fopen failed"); return false; }

    lzma_stream strm = LZMA_STREAM_INIT;
    if (lzma_auto_decoder(&strm, UINT64_MAX, 0) != LZMA_OK) {
        fclose(f); if (error) *error = makeError(@"lzma_auto_decoder init failed"); return false;
    }

    std::vector<uint8_t> inBuf(kDecompChunk);
    std::vector<uint8_t> outBuf(kDecompChunk);
    lzma_action action = LZMA_RUN;
    strm.next_in = nullptr; strm.avail_in = 0;
    bool ok = true;

    for (;;) {
        if (strm.avail_in == 0 && !feof(f)) {
            size_t r = fread(inBuf.data(), 1, inBuf.size(), f);
            if (ferror(f)) { ok = false; if (error) *error = makeError(@"fread error"); break; }
            strm.next_in = inBuf.data();
            strm.avail_in = r;
            if (feof(f)) action = LZMA_FINISH;
        }
        strm.next_out = outBuf.data();
        strm.avail_out = outBuf.size();

        lzma_ret ret = lzma_code(&strm, action);

        size_t produced = outBuf.size() - strm.avail_out;
        if (produced > 0) {
            if (write(outFd, outBuf.data(), produced) != (ssize_t)produced) {
                ok = false; if (error) *error = makeError(@"write error"); break;
            }
        }
        if (ret == LZMA_STREAM_END) break;
        if (ret != LZMA_OK) { ok = false; if (error) *error = makeError(@"lzma_code error"); break; }
    }
    lzma_end(&strm);
    fclose(f);
    return ok;
}

}  // namespace

@implementation KloggDecompressor

+ (BOOL)isDecompressiblePath:(NSString *)path {
    return formatForPath(path) != CompFormat::None;
}

+ (nullable NSString *)decompressToTempFile:(NSString *)path
                                       error:(NSError * _Nullable * _Nullable)error {
    CompFormat fmt = formatForPath(path);
    if (fmt == CompFormat::None) {
        if (error) *error = makeError(@"unsupported archive format");
        return nil;
    }

    // Build a temp file that keeps the inner basename (klogg names the temp after the
    // archive's fileName), so the tab label / encoding heuristics look sensible.
    NSString* base = path.lastPathComponent.stringByDeletingPathExtension;
    if (base.length == 0) base = @"klogg_decompressed";
    NSString* tmpDir = NSTemporaryDirectory();
    NSString* tmpTemplate = [tmpDir stringByAppendingPathComponent:
                              [NSString stringWithFormat:@"klogg_%@_XXXXXX", base]];
    char* tmpl = strdup(tmpTemplate.fileSystemRepresentation);
    int outFd = mkstemp(tmpl);
    if (outFd < 0) {
        free(tmpl);
        if (error) *error = makeError(@"could not create temp file");
        return nil;
    }
    NSString* outPath = [NSString stringWithUTF8String:tmpl];
    free(tmpl);

    bool ok = false;
    switch (fmt) {
        case CompFormat::Gz:  ok = decompressGz(path, outFd, error);  break;
        case CompFormat::Bz2: ok = decompressBz2(path, outFd, error); break;
        case CompFormat::Xz:  ok = decompressXz(path, outFd, error);  break;
        default: break;
    }
    close(outFd);

    if (!ok) {
        [[NSFileManager defaultManager] removeItemAtPath:outPath error:nil];
        return nil;
    }
    return outPath;
}

@end
