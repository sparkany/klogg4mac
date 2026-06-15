//
//  KloggBridge.mm
//  Objective-C++ implementation of the engine facade.
//
//  Two compile modes:
//    * KLOGG_BRIDGE_STUB defined  -> no Qt/engine; serves synthetic content so the
//      AppKit UI can be built and verified before the engine is wired in.
//    * not defined                -> includes the real klogg engine headers and
//      drives LogData / LogFilteredData. (Filled in once libklogg_engine.a builds;
//      requires Qt6 Core + Core5Compat — see macos/README.md.)
//

#import "KloggBridge.h"

#if !defined(KLOGG_BRIDGE_STUB)
// Real engine wiring goes here. Kept behind the flag so stub builds stay Qt-free.
//   #include "logdata.h"
//   #include "logfiltereddata.h"
//   ... own LogData*/LogFilteredData*, connect signals, hop to main queue ...
#error "Real engine mode not yet wired. Build with KLOGG_BRIDGE_STUB (see README) until libklogg_engine.a is available."
#endif

@implementation KloggEngine {
    NSMutableArray<NSString *> *_lines;   // stub backing store
}

+ (BOOL)isStub {
#if defined(KLOGG_BRIDGE_STUB)
    return YES;
#else
    return NO;
#endif
}

- (instancetype)init {
    if ((self = [super init])) {
        _lines = [NSMutableArray array];
    }
    return self;
}

- (void)openFileAtPath:(NSString *)path {
    // Stub: synthesize a large file so the log view can be exercised for scroll /
    // selection / rendering work before the real indexer exists.
    [_lines removeAllObjects];
    NSError *err = nil;
    NSString *real = [NSString stringWithContentsOfFile:path
                                               encoding:NSUTF8StringEncoding
                                                  error:&err];
    if (real && !err) {
        [_lines addObjectsFromArray:[real componentsSeparatedByString:@"\n"]];
    } else {
        for (NSUInteger i = 0; i < 1000000; i++) {
            [_lines addObject:[NSString stringWithFormat:
                @"%@ [stub] line %lu — replace with real engine output",
                path.lastPathComponent, (unsigned long)i]];
        }
    }
    __weak __typeof__(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __typeof__(self) s = weakSelf; if (!s) return;
        if ([s.delegate respondsToSelector:@selector(kloggEngine:loadingProgress:)])
            [s.delegate kloggEngine:s loadingProgress:100];
        if ([s.delegate respondsToSelector:@selector(kloggEngine:loadingFinished:)])
            [s.delegate kloggEngine:s loadingFinished:YES];
    });
}

- (NSUInteger)lineCount { return _lines.count; }

- (NSString *)lineStringAtIndex:(NSUInteger)index {
    if (index >= _lines.count) return nil;
    return _lines[index];
}

- (NSArray<NSString *> *)linesInRange:(NSRange)range expandTabs:(BOOL)expand {
    if (range.location >= _lines.count) return @[];
    NSUInteger end = MIN(range.location + range.length, _lines.count);
    NSRange clamped = NSMakeRange(range.location, end - range.location);
    NSArray<NSString *> *slice = [_lines subarrayWithRange:clamped];
    if (!expand) return slice;
    NSMutableArray<NSString *> *out = [NSMutableArray arrayWithCapacity:slice.count];
    for (NSString *l in slice)
        [out addObject:[l stringByReplacingOccurrencesOfString:@"\t" withString:@"        "]];
    return out;
}

- (void)searchWithPattern:(NSString *)pattern
          caseInsensitive:(BOOL)caseInsensitive
                    regex:(BOOL)isRegex {
    NSUInteger count = 0;
    NSStringCompareOptions opts = caseInsensitive ? NSCaseInsensitiveSearch : 0;
    if (pattern.length) {
        for (NSString *l in _lines)
            if ([l rangeOfString:pattern options:opts].location != NSNotFound) count++;
    }
    __weak __typeof__(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __typeof__(self) s = weakSelf; if (!s) return;
        if ([s.delegate respondsToSelector:@selector(kloggEngine:searchFinished:)])
            [s.delegate kloggEngine:s searchFinished:count];
    });
}

- (void)cancel { /* stub: nothing in flight */ }

@end
