#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Thin Objective-C wrapper around the QVAC TranscribePsy C++ engine.
/// Not thread-safe: call it from one serial queue.
@interface QVACTranscriber : NSObject

- (nullable instancetype)initWithModelPath:(NSString *)path
                                    useGPU:(BOOL)useGPU
                                     error:(NSError **)error NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Transcribes 16 kHz mono float PCM.
- (NSString *)transcribeSamples:(const float *)samples count:(NSInteger)count;

/// Human-readable backend, e.g. "Metal" or "CPU".
@property (nonatomic, readonly) NSString *backendName;

@end

NS_ASSUME_NONNULL_END
