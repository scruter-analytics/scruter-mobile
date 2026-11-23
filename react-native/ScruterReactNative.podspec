require 'json'

package = JSON.parse(File.read(File.join(__dir__, 'package.json')))

# The modules the app takes (docs/CMP-MOBILE.md §3.16, M2): its package.json's "scruter" key, read here and by
# android/build.gradle. Scruter Analytics unless "analytics": false; Scruter CMP with "cmp": true. An app carries only
# the native code of what it takes.
# A lambda, not a method: CocoaPods evaluates a podspec inside its own module.
scruter_modules = lambda do
  app = File.expand_path('../package.json', Pod::Config.instance.installation_root.to_s)
  config = File.exist?(app) ? (JSON.parse(File.read(app))['scruter'] || {}) : {}
  modules = { analytics: config['analytics'] != false, cmp: config['cmp'] == true }
  raise '[Scruter] "scruter": { "analytics": false } without "cmp": true leaves nothing to install' unless modules.values.any?
  modules
end

Pod::Spec.new do |s|
  modules = scruter_modules.call

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
  # CocoaPods trunk is read-only from 2026-12-02 (docs/MOBILE.md §20). With both modules, Scruter Analytics and Scruter
  # CMP share this pod's Swift module: their internal names stay apart (docs/CMP-MOBILE.md §3.16).
  sources = []
  resources = {}
  frameworks = ['Foundation', 'UIKit', 'SwiftUI', 'SafariServices']
  if modules[:analytics]
    sources += ['ios/*.{h,mm,swift}', 'ios/sdk/ScruterAnalytics/**/*.swift', 'ios/sdk/ScruterCrash/**/*.{h,c}']
    resources['ScruterAnalytics_Privacy'] = ['ios/sdk/ScruterAnalytics/PrivacyInfo.xcprivacy']
    frameworks += ['Security', 'StoreKit', 'UserNotifications', 'WebKit']
    s.public_header_files = 'ios/sdk/ScruterCrash/include/ScruterCrash.h'
    s.weak_frameworks     = 'MetricKit', 'AdAttributionKit'
  else
    # Its name stays known to the module providers of package.json's codegenConfig: a stub, none of the SDK's code.
    sources += ['ios/ScruterModule.h', 'ios/analytics-off/*.mm']
  end
  if modules[:cmp]
    sources += ['ios/cmp/*.{h,mm,swift}', 'ios/sdk/ScruterCMP/**/*.swift']
    resources['ScruterCMP_Privacy'] = ['ios/sdk/ScruterCMP/PrivacyInfo.xcprivacy']
    frameworks += ['AVFoundation', 'Network']
  else
    sources += ['ios/cmp/ScruterCMPModule.h', 'ios/cmp-off/*.mm']
  end
  s.source_files     = sources
  # The Swift half sees this module's public headers: C++ must not reach it through the umbrella header.
  s.private_header_files = ['ios/ScruterModule.h', 'ios/cmp/ScruterCMPModule.h']
  s.resource_bundles = resources
  s.frameworks       = frameworks.uniq
  s.pod_target_xcconfig = { 'SWIFT_OPTIMIZATION_LEVEL' => '-Osize', 'DEFINES_MODULE' => 'YES' }

  if respond_to?(:install_modules_dependencies, true)
    install_modules_dependencies(s)
  else
    s.dependency 'React-Core'
  end
end
