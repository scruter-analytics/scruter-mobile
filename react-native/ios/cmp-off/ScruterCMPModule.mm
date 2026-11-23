#import "../cmp/ScruterCMPModule.h"

#import <React/RCTLog.h>

/// Scruter CMP left out (the default: "scruter": { "cmp": true } in the app's package.json takes it): the module's name
/// stays known to React Native's module providers (codegenConfig), its calls grant nothing and carry none of its code.
@implementation ScruterCMPModule

RCT_EXPORT_MODULE(ScruterCMP)

+ (BOOL)requiresMainQueueSetup {
  return NO;
}

- (NSArray<NSString *> *)supportedEvents {
  return @[ @"ScruterCMPChange" ];
}

RCT_EXPORT_SYNCHRONOUS_TYPED_METHOD(NSNumber *, start : (NSDictionary *)options) {
  RCTLogWarn(@"[ScruterCMP] Scruter CMP is not in this app: add \"scruter\": { \"cmp\": true } to package.json, then pod install and rebuild");
  return @NO;
}

RCT_EXPORT_SYNCHRONOUS_TYPED_METHOD(NSDictionary *, snapshot) {
  return @{@"state" : @"unavailable", @"granted" : @[ @"necessary" ], @"signals" : @{@"security_storage" : @"granted"}};
}

RCT_EXPORT_METHOD(showPreferences) {}

RCT_EXPORT_SYNCHRONOUS_TYPED_METHOD(NSNumber *, showIfNeeded) {
  return @NO;
}

RCT_EXPORT_METHOD(requestTrackingIfGranted : (RCTPromiseResolveBlock)resolve reject : (RCTPromiseRejectBlock)reject) {
  resolve(@"notDetermined");
}

RCT_EXPORT_METHOD(setLanguage : (NSString *)language) {}
RCT_EXPORT_METHOD(setDebug : (BOOL)on) {}
RCT_EXPORT_METHOD(setForceShow : (BOOL)on) {}
RCT_EXPORT_METHOD(debugReset) {}

#ifdef SCRUTER_CMP_TURBO
- (std::shared_ptr<facebook::react::TurboModule>)getTurboModule:(const facebook::react::ObjCTurboModule::InitParams &)params {
  return std::make_shared<facebook::react::NativeScruterCMPSpecJSI>(params);
}
#endif

@end
