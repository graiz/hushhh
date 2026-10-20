#import "QVACTranscriber.h"

#include <parakeet/engine.h>
#include <memory>
#include <exception>

@implementation QVACTranscriber {
    std::unique_ptr<parakeet::Engine> _engine;
}

- (nullable instancetype)initWithModelPath:(NSString *)path
                                    useGPU:(BOOL)useGPU
                                     error:(NSError **)error {
    self = [super init];
    if (!self) return nil;
    try {
        parakeet::EngineOptions opts;
        opts.model_gguf_path = path.UTF8String;
        opts.n_gpu_layers = useGPU ? 99 : 0;
        opts.prewarm = true;
        _engine = std::make_unique<parakeet::Engine>(opts);
    } catch (const std::exception &e) {
        if (error) {
            *error = [NSError errorWithDomain:@"QVACTranscriber" code:1 userInfo:@{
                NSLocalizedDescriptionKey: [NSString stringWithUTF8String:e.what()] ?: @"The QVAC model couldn’t be loaded."
            }];
        }
        return nil;
    }
    return self;
}

- (NSString *)transcribeSamples:(const float *)samples count:(NSInteger)count {
    if (!_engine || count <= 0) return @"";
    try {
        parakeet::EngineResult r = _engine->transcribe_samples(samples, (int)count, 16000);
        return [NSString stringWithUTF8String:r.text.c_str()] ?: @"";
    } catch (const std::exception &e) {
        NSLog(@"[Hushhh] QVAC transcription failed: %s", e.what());
        return @"";
    }
}

- (NSString *)backendName {
    if (!_engine) return @"—";
    return [NSString stringWithUTF8String:_engine->backend_name().c_str()] ?: @"CPU";
}

@end
