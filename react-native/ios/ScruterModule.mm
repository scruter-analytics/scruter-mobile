#import "ScruterModule.h"

#import <UIKit/UIKit.h>

#if __has_include(<ScruterReactNative/ScruterReactNative-Swift.h>)
#import <ScruterReactNative/ScruterReactNative-Swift.h>
#else
#import "ScruterReactNative-Swift.h"
#endif

/// The JavaScript API, for both architectures. Void methods run in order on the main queue: `start` needs it, and what
/// follows it in JavaScript must find the SDK started. They only hand over to the SDK's own queue.
/// What the app was launched with: JavaScript starts the SDK long after.
static NSDictionary *launchOptions = nil;

__attribute__((constructor)) static void watchLaunch(void) {
  [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                    object:nil
                                                     queue:nil
                                                usingBlock:^(NSNotification *note) {
                                                  launchOptions = note.userInfo;
                                                }];
}

@implementation ScruterModule

RCT_EXPORT_MODULE(Scruter)

+ (BOOL)requiresMainQueueSetup {
  return YES;
}

- (dispatch_queue_t)methodQueue {
  return dispatch_get_main_queue();
}

- (NSArray<NSString *> *)supportedEvents {
  return @[ @"ScruterLog" ];
}

RCT_EXPORT_METHOD(start : (NSDictionary *)options) {
  __weak ScruterModule *weakSelf = self;
  void (^log)(NSString *) = nil;
  if ([options[@"debug"] boolValue]) {
    log = ^(NSString *line) {
      [weakSelf sendEventWithName:@"ScruterLog" body:line];
    };
  }
  [ScruterHost start:options launchOptions:launchOptions log:log];
  launchOptions = nil;
}

RCT_EXPORT_METHOD(screen : (NSString *)name forward : (BOOL)forward) {
  [ScruterHost screen:name forward:forward];
}

RCT_EXPORT_METHOD(track : (NSString *)name event : (NSDictionary *)event) {
  [ScruterHost track:name event:event];
}

RCT_EXPORT_METHOD(fieldError : (NSString *)key kind : (NSString *)kind) {
  [ScruterHost fieldError:key kind:kind];
}

RCT_EXPORT_METHOD(formSent : (NSString *)name) {
  [ScruterHost formSent:name];
}

RCT_EXPORT_METHOD(optOut) {
  [ScruterHost optOut];
}

RCT_EXPORT_METHOD(optIn) {
  [ScruterHost optIn];
}

RCT_EXPORT_SYNCHRONOUS_TYPED_METHOD(NSNumber *, isOptedOut) {
  return @(ScruterHost.isOptedOut);
}

RCT_EXPORT_METHOD(ignoreThisDevice) {
  [ScruterHost ignoreThisDevice];
}

RCT_EXPORT_METHOD(stopIgnoringThisDevice) {
  [ScruterHost stopIgnoringThisDevice];
}

RCT_EXPORT_SYNCHRONOUS_TYPED_METHOD(NSNumber *, isDeviceIgnored) {
  return @(ScruterHost.isDeviceIgnored);
}

RCT_EXPORT_METHOD(handle : (NSString *)url) {
  [ScruterHost handle:url];
}

RCT_EXPORT_METHOD(openedFromNotification) {
  [ScruterHost openedFromNotification];
}

RCT_EXPORT_SYNCHRONOUS_TYPED_METHOD(NSNumber *, isTeamPhone) {
  return @(ScruterHost.isTeamPhone);
}

RCT_EXPORT_METHOD(leaveTeamMode) {
  [ScruterHost leaveTeamMode];
}

RCT_EXPORT_METHOD(flush) {
  [ScruterHost flush];
}

RCT_EXPORT_SYNCHRONOUS_TYPED_METHOD(NSNumber *, reportError : (BOOL)fatal type : (NSString *)type reason : (NSString *)reason frames : (NSArray *)frames bundleId : (NSString *)bundleId) {
  [ScruterHost reportErrorWithFatal:fatal type:type reason:reason frames:frames bundleId:bundleId];
  return @YES;
}

RCT_EXPORT_SYNCHRONOUS_TYPED_METHOD(NSString *, defaultBundleId) {
  return ScruterHost.defaultBundleId;
}

#ifdef SCRUTER_TURBO
- (std::shared_ptr<facebook::react::TurboModule>)getTurboModule:(const facebook::react::ObjCTurboModule::InitParams &)params {
  return std::make_shared<facebook::react::NativeScruterSpecJSI>(params);
}
#endif

@end
