//
//  KloggBridge.h
//  Objective-C facade exposing the klogg C++ engine to Swift/AppKit.
//
//  Design rule (see docs/native-macos/ROADMAP.md §1): the UI layer never sees a
//  Qt type. Everything below is plain Foundation. The .mm implementation owns the
//  C++ engine objects (LogData / LogFilteredData) and converts QString<->NSString,
//  marshals worker-thread signals onto the main thread, and supports cancellation.
//
//  This header is the contract between `bridge` and the UI engineers; it mirrors
//  the real engine API (AbstractLogData::getLineString/getNbLine, LogData::attachFile
//  + loadingProgressed/loadingFinished signals, LogFilteredData for search).
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Progress of a long-running engine operation (indexing / searching).
@protocol KloggEngineDelegate <NSObject>
@optional
/// 0–100. Always delivered on the main thread.
- (void)kloggEngine:(id)engine loadingProgress:(int)percent;
/// Delivered on the main thread when attach/reload completes.
- (void)kloggEngine:(id)engine loadingFinished:(BOOL)success;
/// Delivered on the main thread when a search completes; `matchCount` is total hits.
- (void)kloggEngine:(id)engine searchFinished:(NSUInteger)matchCount;
/// Delivered periodically during search; `matchCount` hits so far, `percent` 0-100.
/// Always on the main thread. Optional — implement for a live-updating count display.
- (void)kloggEngine:(id)engine searchProgressed:(NSUInteger)matchCount percent:(int)percent;
@end

/// Thin owner of one open log file. One instance per tab/document.
@interface KloggEngine : NSObject

@property (nonatomic, weak, nullable) id<KloggEngineDelegate> delegate;

/// Whether this build links the real engine. NO in stub mode.
@property (class, nonatomic, readonly) BOOL isStub;

/// Begin attaching/indexing a file. Returns immediately; progress arrives via delegate.
/// Must be called once per engine; re-attaching the same engine throws. Use `reload`
/// to re-index a file that is already attached.
- (void)openFileAtPath:(NSString *)path;

/// Re-index the already-attached file (picks up appended/changed content), as klogg's
/// Reload does. Returns immediately; loadingProgress/loadingFinished arrive via delegate.
/// No-op if no file has been attached yet.
- (void)reload;

/// Total number of lines in the source (valid after loadingFinished:YES).
- (NSUInteger)lineCount;

/// Raw text for a line (tabs not expanded). Bounds-checked; nil if out of range.
- (nullable NSString *)lineStringAtIndex:(NSUInteger)index;

/// A contiguous block of lines, for the visible viewport. Never nil; may be short.
- (NSArray<NSString *> *)linesInRange:(NSRange)range expandTabs:(BOOL)expand;

/// Start a search; results feed a filtered view. Progress/completion via delegate.
- (void)searchWithPattern:(NSString *)pattern
              caseInsensitive:(BOOL)caseInsensitive
                        regex:(BOOL)isRegex;

// MARK: - Filtered data access (valid after searchFinished)

/// Number of matching lines from the last search (0 if no search done).
- (NSUInteger)searchMatchCount;

/// The original source-file line index (0-based) for match at `matchIndex`.
/// Returns NSNotFound if out of range.
- (NSUInteger)searchMatchLineAtIndex:(NSUInteger)matchIndex;

/// Text of filtered matches in `range` (indices into the match list, not source lines).
/// Equivalent to linesInRange but reading from LogFilteredData.
/// Never nil; may be short if range exceeds match count.
- (NSArray<NSString *> *)filteredLinesInRange:(NSRange)range expandTabs:(BOOL)expand;

/// Cancel any in-flight open/index/search.
- (void)cancel;

@end

NS_ASSUME_NONNULL_END
