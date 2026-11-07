Pod::Spec.new do |s|
  s.name             = 'Scruter'
  s.version          = '1.0.2'
  s.summary          = 'Scruter Analytics for iOS: privacy-first app analytics, no IDFA, no ATT prompt, no banner.'
  s.description      = <<-DESC
    Screens, events, sessions, retention, crashes and Screen analysis for iOS apps, hosted in France.
    The SDK draws a random identifier each day and forgets it at midnight; it never reads the IDFA, never shows an
    App Tracking Transparency prompt and never captures a user's screen.
  DESC
  s.homepage         = 'https://scruter.net'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { '1618 Technologies (Scruter)' => 'contact@scruter.net' }
  s.source           = { :git => 'https://github.com/scruter-analytics/scruter-mobile.git', :tag => s.version.to_s }
  s.documentation_url = 'https://github.com/scruter-analytics/scruter-mobile/blob/main/ios/README.md'

  s.ios.deployment_target = '15.0'
  s.swift_versions   = ['5.9']
  s.module_name      = 'ScruterAnalytics'
  s.requires_arc     = true
  # CocoaPods allows what a Swift package may not: the SDK built for size (ios/README.md, budget table).
  s.pod_target_xcconfig = { 'SWIFT_OPTIMIZATION_LEVEL' => '-Osize' }

  s.source_files        = 'ios/Sources/ScruterAnalytics/**/*.swift', 'ios/Sources/ScruterCrash/**/*.{c,h}'
  s.public_header_files = 'ios/Sources/ScruterCrash/include/ScruterCrash.h'
  s.resource_bundles    = { 'ScruterAnalytics_Privacy' => ['ios/Sources/ScruterAnalytics/PrivacyInfo.xcprivacy'] }
  s.preserve_paths      = 'ios/upload-symbols'
  s.frameworks          = 'Foundation', 'UIKit', 'SwiftUI', 'Security', 'StoreKit', 'UserNotifications', 'WebKit', 'SafariServices'
  s.weak_frameworks     = 'MetricKit', 'AdAttributionKit'
end
