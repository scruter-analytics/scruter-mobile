Pod::Spec.new do |s|
  s.name             = 'scruter_flutter'
  s.version          = '1.0.0'
  s.summary          = 'Scruter Analytics for Flutter: privacy-first app analytics, no IDFA, no ATT prompt, no banner.'
  s.homepage         = 'https://scruter.net'
  s.license          = { :type => 'MIT', :file => '../LICENSE' }
  s.author           = { '1618 Technologies (Scruter)' => 'contact@scruter.net' }
  s.source           = { :path => '.' }

  # The iOS SDK's sources travel with the plugin: a podspec cannot name a git source, and the CocoaPods trunk turns
  # read-only on 2026-12-02 (docs/MOBILE.md §3 "Distribution"). Swift Package Manager reads Package.swift instead.
  unless Dir.exist?(File.join(__dir__, 'vendor', 'ScruterAnalytics'))
    raise 'ios/vendor is missing: run scripts/sync-ios-sources.sh'
  end
  s.source_files        = 'scruter_flutter/Sources/scruter_flutter/**/*.swift',
                          'vendor/ScruterAnalytics/**/*.swift',
                          'vendor/ScruterCrash/**/*.{c,h}'
  s.public_header_files = 'vendor/ScruterCrash/include/ScruterCrash.h'
  s.resource_bundles    = { 'ScruterAnalytics_Privacy' => ['vendor/ScruterAnalytics/PrivacyInfo.xcprivacy'] }
  s.frameworks          = 'Foundation', 'UIKit', 'SwiftUI', 'Security', 'StoreKit', 'UserNotifications', 'WebKit', 'SafariServices'
  s.weak_frameworks     = 'MetricKit', 'AdAttributionKit'

  s.dependency 'Flutter'
  s.platform         = :ios, '15.0'
  s.swift_version    = '5.9'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'SWIFT_OPTIMIZATION_LEVEL' => '-Osize' }
end
