#import <React/RCTEventEmitter.h>

#if __has_include(<RNScruterSpec/RNScruterSpec.h>)
#import <RNScruterSpec/RNScruterSpec.h>
#define SCRUTER_CMP_TURBO 1
@interface ScruterCMPModule : RCTEventEmitter <NativeScruterCMPSpec>
@end
#else
#import <React/RCTBridgeModule.h>
@interface ScruterCMPModule : RCTEventEmitter <RCTBridgeModule>
@end
#endif
