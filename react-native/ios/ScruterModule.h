#import <React/RCTEventEmitter.h>

#if __has_include(<RNScruterSpec/RNScruterSpec.h>)
#import <RNScruterSpec/RNScruterSpec.h>
#define SCRUTER_TURBO 1
@interface ScruterModule : RCTEventEmitter <NativeScruterSpec>
@end
#else
#import <React/RCTBridgeModule.h>
@interface ScruterModule : RCTEventEmitter <RCTBridgeModule>
@end
#endif
