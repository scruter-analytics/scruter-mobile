require 'yaml'

# The modules the app takes (docs/CMP-MOBILE.md §3.16, M2): the `scruter` key of its pubspec.yaml, read here, by
# android/build.gradle and by Package.swift. Scruter Analytics unless `analytics: false`; Scruter CMP with `cmp: true`.
# An app carries only the native code of what it takes.
# A lambda, not a method: CocoaPods evaluates a podspec inside its own module.
scruter_modules = lambda do
  app = File.expand_path('../pubspec.yaml', Pod::Config.instance.installation_root.to_s)
  config = File.exist?(app) ? ((YAML.safe_load(File.read(app)) || {})['scruter'] || {}) : {}
  modules = { analytics: config['analytics'] != false, cmp: config['cmp'] == true }
  raise '[Scruter] `scruter: { analytics: false }` without `cmp: true` leaves nothing to install' unless modules.values.any?
  modules
end

Pod::Spec.new do |s|
  modules = scruter_modules.call

  s.name             = 'scruter_flutter'
  s.version          = '1.2.0'
  s.summary          = 'Scruter Analytics and Scruter CMP for Flutter: privacy-first app analytics, the consent sheet of Scruter CMP.'
  s.homepage         = 'https://scruter.net'
  s.license          = { :type => 'MIT', :file => '../LICENSE' }
  s.author           = { '1618 Technologies (Scruter)' => 'contact@scruter.net' }
  s.source           = { :path => '.' }

  # The iOS SDK's sources travel with the plugin: a podspec cannot name a git source, and the CocoaPods trunk turns
  # read-only on 2026-12-02 (docs/MOBILE.md §3 "Distribution"). Swift Package Manager reads Package.swift instead. With
  # both modules, Scruter Analytics and Scruter CMP share this pod's Swift module: their internal names stay apart.
  unless Dir.exist?(File.join(__dir__, 'vendor', 'ScruterAnalytics')) && Dir.exist?(File.join(__dir__, 'vendor', 'ScruterCMP'))
    raise 'ios/vendor is missing: run scripts/sync-ios-sources.sh'
  end
  sources = ['scruter_flutter/Sources/scruter_flutter/ScruterFlutterPlugin.swift']
  resources = {}
  frameworks = ['Foundation', 'UIKit', 'SwiftUI', 'SafariServices']
  conditions = ['$(inherited)']
  if modules[:analytics]
    sources += ['scruter_flutter/Sources/scruter_flutter/ScruterAnalyticsPlugin.swift',
                'vendor/ScruterAnalytics/**/*.swift', 'vendor/ScruterCrash/**/*.{c,h}']
    resources['ScruterAnalytics_Privacy'] = ['vendor/ScruterAnalytics/PrivacyInfo.xcprivacy']
    frameworks += ['Security', 'StoreKit', 'UserNotifications', 'WebKit']
    conditions << 'SCRUTER_ANALYTICS'
    s.public_header_files = 'vendor/ScruterCrash/include/ScruterCrash.h'
    s.weak_frameworks     = 'MetricKit', 'AdAttributionKit'
  end
  if modules[:cmp]
    sources += ['scruter_flutter/Sources/scruter_flutter/ScruterCMPPlugin.swift', 'vendor/ScruterCMP/**/*.swift']
    resources['ScruterCMP_Privacy'] = ['vendor/ScruterCMP/PrivacyInfo.xcprivacy']
    frameworks += ['AVFoundation', 'Network']
    conditions << 'SCRUTER_CMP'
  end
  s.source_files     = sources
  s.resource_bundles = resources
  s.frameworks       = frameworks.uniq

  s.dependency 'Flutter'
  s.platform         = :ios, '15.0'
  s.swift_version    = '5.9'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES', 'SWIFT_OPTIMIZATION_LEVEL' => '-Osize',
    'SWIFT_ACTIVE_COMPILATION_CONDITIONS' => conditions.join(' '),
  }
end
