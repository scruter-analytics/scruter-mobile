import Flutter
import UIKit

/// The plugin Flutter registers: Scruter Analytics and Scruter CMP, each compiled only when the app's pubspec.yaml takes
/// it (`scruter: { analytics: false, cmp: true }`, docs/CMP-MOBILE.md §3.16). The podspec and Package.swift set the
/// conditions and leave the other module's code out.
public final class ScruterFlutterPlugin: NSObject, FlutterPlugin {
    public static func register(with registrar: FlutterPluginRegistrar) {
        #if SCRUTER_ANALYTICS
        ScruterAnalyticsPlugin.register(with: registrar)
        #endif
        #if SCRUTER_CMP
        ScruterCMPPlugin.register(with: registrar)
        #endif
    }
}
