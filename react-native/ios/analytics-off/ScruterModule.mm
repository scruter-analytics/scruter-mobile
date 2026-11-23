#import "../ScruterModule.h"

#import <React/RCTLog.h>

/// Scruter Analytics left out ("scruter": { "analytics": false } in the app's package.json): the module's name stays
/// known to React Native's module providers (codegenConfig), its calls do nothing and carry none of the SDK's code.
@implementation ScruterModule

RCT_EXPORT_MODULE(Scruter)

+ (BOOL)requiresMainQueueSetup {
  return NO;
}

- (NSArray<NSString *> *)supportedEvents {
  return @[ @"ScruterLog" ];
}

RCT_EXPORT_METHOD(start : (NSDictionary *)options) {
  RCTLogWarn(@"[Scruter] Scruter Analytics is left out of this app (\"scruter\": { \"analytics\": false } in package.json): nothing is measured");
}

RCT_EXPORT_METHOD(screen : (NSString *)name forward : (BOOL)forward) {}
RCT_EXPORT_METHOD(track : (NSString *)name event : (NSDictionary *)event) {}
RCT_EXPORT_METHOD(fieldError : (NSString *)key kind : (NSString *)kind) {}
RCT_EXPORT_METHOD(formSent : (NSString *)name) {}
RCT_EXPORT_METHOD(optOut) {}
RCT_EXPORT_METHOD(optIn) {}
RCT_EXPORT_SYNCHRONOUS_TYPED_METHOD(NSNumber *, isOptedOut) {
  return @NO;
}
RCT_EXPORT_METHOD(ignoreThisDevice) {}
RCT_EXPORT_METHOD(stopIgnoringThisDevice) {}
RCT_EXPORT_SYNCHRONOUS_TYPED_METHOD(NSNumber *, isDeviceIgnored) {
  return @NO;
}
RCT_EXPORT_METHOD(handle : (NSString *)url) {}
RCT_EXPORT_METHOD(openedFromNotification) {}
RCT_EXPORT_SYNCHRONOUS_TYPED_METHOD(NSNumber *, isTeamPhone) {
  return @NO;
}
RCT_EXPORT_METHOD(leaveTeamMode) {}
RCT_EXPORT_METHOD(flush) {}
RCT_EXPORT_SYNCHRONOUS_TYPED_METHOD(NSNumber *, reportError : (BOOL)fatal type : (NSString *)type reason : (NSString *)reason frames : (NSArray *)frames bundleId : (NSString *)bundleId) {
  return @NO;
}
RCT_EXPORT_SYNCHRONOUS_TYPED_METHOD(NSString *, defaultBundleId) {
  return @"";
}

#ifdef SCRUTER_TURBO
- (std::shared_ptr<facebook::react::TurboModule>)getTurboModule:(const facebook::react::ObjCTurboModule::InitParams &)params {
  return std::make_shared<facebook::react::NativeScruterSpecJSI>(params);
}
#endif

@end
