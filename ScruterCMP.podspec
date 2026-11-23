Pod::Spec.new do |s|
  s.name             = 'ScruterCMP'
  s.version          = '1.2.0'
  s.summary          = 'Scruter CMP for iOS: the consent banner of your Scruter CMP as a native sheet, and the proof of every choice.'
  s.description      = <<-DESC
    The consent management platform of Scruter for iOS apps: a native SwiftUI sheet drawn from the banner you publish in
    Scruter CMP (texts, colours, media, languages, A/B tests), the choice kept in the app's own storage, a proof of
    every decision, the re-ask rules of the web, Google Consent Mode signals and Apple's tracking prompt after the CMP.
    No IDFA, no device identifier, no third-party dependency. Independent of Scruter Analytics.
  DESC
  s.homepage         = 'https://scruter.net/cmp'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { '1618 Technologies (Scruter)' => 'contact@scruter.net' }
  s.source           = { :git => 'https://github.com/scruter-analytics/scruter-mobile.git', :tag => s.version.to_s }
  s.documentation_url = 'https://github.com/scruter-analytics/scruter-mobile/blob/main/ios/CMP.md'

  s.ios.deployment_target = '15.0'
  s.swift_versions   = ['5.9']
  s.module_name      = 'ScruterCMP'
  s.requires_arc     = true
  s.pod_target_xcconfig = { 'SWIFT_OPTIMIZATION_LEVEL' => '-Osize' }

  s.source_files     = 'ios/Sources/ScruterCMP/**/*.swift'
  s.resource_bundles = { 'ScruterCMP_Privacy' => ['ios/Sources/ScruterCMP/PrivacyInfo.xcprivacy'] }
  s.frameworks       = 'Foundation', 'SwiftUI', 'UIKit', 'SafariServices', 'AVFoundation', 'Network'
end
