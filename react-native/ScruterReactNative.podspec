require 'json'

package = JSON.parse(File.read(File.join(__dir__, 'package.json')))

Pod::Spec.new do |s|
  s.name         = 'ScruterReactNative'
  s.version      = package['version']
  s.summary      = package['description']
  s.homepage     = package['homepage']
  s.license      = package['license']
  s.author       = { '1618 Technologies (Scruter)' => 'contact@scruter.net' }
  s.platforms    = { :ios => '15.0' }
  s.source       = { :git => 'https://github.com/scruter-analytics/scruter-mobile.git', :tag => s.version.to_s }
  s.swift_version = '5.9'
  s.module_name  = 'ScruterReactNative'

  # The iOS SDK is compiled here, from the copy npm installs (scripts/sync-ios.mjs), never through a trunk pod:
  # CocoaPods trunk is read-only from 2026-12-02 (docs/MOBILE.md §20).
  s.source_files        = 'ios/**/*.{h,c,mm,swift}'
  s.public_header_files = 'ios/sdk/ScruterCrash/include/ScruterCrash.h'
  # The Swift half sees this module's public headers: C++ must not reach it through the umbrella header.
  s.private_header_files = 'ios/ScruterModule.h'
  s.resource_bundles    = { 'ScruterAnalytics_Privacy' => ['ios/sdk/ScruterAnalytics/PrivacyInfo.xcprivacy'] }
  s.frameworks          = 'Foundation', 'UIKit', 'SwiftUI', 'Security', 'StoreKit', 'UserNotifications', 'WebKit', 'SafariServices'
  s.weak_frameworks     = 'MetricKit', 'AdAttributionKit'
  s.pod_target_xcconfig = { 'SWIFT_OPTIMIZATION_LEVEL' => '-Osize', 'DEFINES_MODULE' => 'YES' }

  if respond_to?(:install_modules_dependencies, true)
    install_modules_dependencies(s)
  else
    s.dependency 'React-Core'
  end
end
