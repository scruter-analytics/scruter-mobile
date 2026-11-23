import Foundation

/// The SDK's version, sent as `sv` with the configuration request and as `cv` (`ios/1.1.0`) with every beacon.
public let scruterCMPVersion = "1.2.0"

/// A JSON object as `JSONSerialization` reads it. The module reads its few documents by hand rather than through
/// `Codable`, whose generated code would cost the app more than the rest of the logic (§3.11, the size budget).
typealias JSONObject = [String: Any]

extension Dictionary where Key == String, Value == Any {
    @_optimize(size) func str(_ k: String) -> String? { self[k] as? String }
    @_optimize(size) func int(_ k: String) -> Int? { (self[k] as? NSNumber).map { $0.intValue } }
    @_optimize(size) func int64(_ k: String) -> Int64? { (self[k] as? NSNumber).map { $0.int64Value } }
    @_optimize(size) func bool(_ k: String) -> Bool? { self[k] as? Bool }
    @_optimize(size) func obj(_ k: String) -> JSONObject? { self[k] as? JSONObject }
    @_optimize(size) func objs(_ k: String) -> [JSONObject]? { self[k] as? [JSONObject] }
    @_optimize(size) func strs(_ k: String) -> [String]? { self[k] as? [String] }
}

enum JSON {
    @_optimize(size) static func object(_ data: Data?) -> JSONObject? {
        data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? JSONObject }
    }

    @_optimize(size) static func list(_ data: Data?) -> [JSONObject]? {
        data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [JSONObject] }
    }

    @_optimize(size) static func data(_ value: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data("{}".utf8)
    }
}

/// `GET /m/v1/cmp` (docs/CMP-MOBILE.md §4.1, `sdk/protocol/schema/cmp-config.schema.json`): the site script's
/// configuration without what only a page uses, plus the app block. Unknown fields are ignored.
final class AppConfig {
    var v: Int
    /// 0: unknown app, a site's code, no published banner, CMP removed or suspended: show nothing, grant nothing.
    var on: Int
    var ttl: Int
    var config: CMPConfig?
    var app: AppBlock?

    @_optimize(size) init?(json j: JSONObject) {
        guard let v = j.int("v"), let on = j.int("on") else { return nil }
        self.v = v
        self.on = on
        ttl = j.int("ttl") ?? 300
        config = j.obj("config").flatMap(CMPConfig.init(json:))
        app = j.obj("app").flatMap(AppBlock.init(json:))
    }

    @_optimize(size) convenience init?(data: Data) {
        guard let j = JSON.object(data) else { return nil }
        self.init(json: j)
    }

    /// A configuration the SDK can draw and prove (`on: 1` with its two blocks).
    var usable: (CMPConfig, AppBlock)? {
        guard v == 1, on == 1, let c = config, let a = app, c.format == 1, !c.purposes.isEmpty,
            c.ui.texts[c.ui.default_language] != nil
        else { return nil }
        return (c, a)
    }
}

struct AppBlock {
    var policy_url: String?
    var icon: String?
    var ids: [String]
    var sdk_catalogue: Int

    @_optimize(size) init?(json j: JSONObject) {
        guard let c = j.int("sdk_catalogue") else { return nil }
        policy_url = j.str("policy_url")
        icon = j.str("icon")
        ids = j.strs("ids") ?? []
        sdk_catalogue = c
    }
}

/// `ScriptConfig` (`scruter_cmp::script`, `cmp/src/config.ts`), the fields an app reads.
final class CMPConfig {
    var format: Int
    var site: String
    var config_rev: Int
    var consent_rev: Int
    var endpoint: String
    var banner: BannerRef
    var ab_test: ABTest?
    var renew_months: Int
    var purposes: [PurposeRef]
    var gcm: GcmSettings?
    /// The IAB TCF settings: read by lot cmp-mobile-tcf (§6); until then the standard layers show.
    var tcf: JSONObject?
    var ui: UiConfig

    @_optimize(size) init?(json j: JSONObject) {
        guard let format = j.int("format"), let site = j.str("site"), let endpoint = j.str("endpoint"),
            let banner = j.obj("banner").flatMap(BannerRef.init(json:)), let ui = j.obj("ui").flatMap(UiConfig.init(json:))
        else { return nil }
        self.format = format
        self.site = site
        self.endpoint = endpoint
        self.banner = banner
        self.ui = ui
        config_rev = j.int("config_rev") ?? 0
        consent_rev = j.int("consent_rev") ?? 1
        ab_test = j.obj("ab_test").flatMap(ABTest.init(json:))
        renew_months = j.obj("cookie")?.int("renew_months") ?? 6
        purposes = (j.objs("purposes") ?? []).compactMap(PurposeRef.init(json:))
        gcm = j.obj("gcm").flatMap(GcmSettings.init(json:))
        tcf = j.obj("tcf")
    }

    var optional: [PurposeRef] { purposes.filter { !$0.required } }
}

struct BannerRef {
    var id: Int
    var version: Int

    @_optimize(size) init?(json j: JSONObject) {
        guard let id = j.int("id") else { return nil }
        self.id = id
        version = j.int("version") ?? 0
    }
}

final class ABTest {
    var id: String
    /// Share of displays drawn into B (10–90).
    var split_b: Int
    var b: BannerRef
    var b_ui: UiConfig

    @_optimize(size) init?(json j: JSONObject) {
        guard let id = j.str("id"), let split = j.int("split_b"), let b = j.obj("b").flatMap(BannerRef.init(json:)),
            let ui = j.obj("b_ui").flatMap(UiConfig.init(json:))
        else { return nil }
        self.id = id
        split_b = split
        self.b = b
        b_ui = ui
    }
}

struct PurposeRef {
    var key: String
    var required: Bool
    var rev: Int

    @_optimize(size) init(key: String, required: Bool, rev: Int) {
        self.key = key
        self.required = required
        self.rev = rev
    }

    @_optimize(size) init?(json j: JSONObject) {
        guard let k = j.str("key") else { return nil }
        self.init(key: k, required: j.bool("required") ?? false, rev: j.int("rev") ?? 1)
    }
}

struct GcmSettings {
    var mode: String
    /// Google signal → purpose key.
    var map: [String: String]

    @_optimize(size) init?(json j: JSONObject) {
        guard let m = j["map"] as? [String: String] else { return nil }
        mode = j.str("mode") ?? "basic"
        map = m
    }
}

final class UiConfig {
    var theme: String
    var color: String
    var logo_mode: String?
    var logo_url: String?
    var buttons: String?
    var close_link: Bool
    var branding: Bool
    var delay_s: Int?
    var languages: [String]
    var default_language: String
    var texts: [String: Texts]
    var text_hashes: [String: String]
    var rtl: [String]?
    var aliases: [String: String]?
    var providers: [String: [String]]?
    var hero: HeroUi?
    var no_panel: Bool?

    @_optimize(size) init?(json j: JSONObject) {
        guard let lang = j.str("default_language") else { return nil }
        default_language = lang
        theme = j.str("theme") ?? "light"
        color = j.str("color") ?? "#6B4EFF"
        logo_mode = j.str("logo_mode")
        logo_url = j.str("logo_url")
        buttons = j.str("buttons")
        close_link = j.bool("close_link") ?? true
        branding = j.bool("branding") ?? false
        delay_s = j.int("delay_s")
        languages = j.strs("languages") ?? [lang]
        texts = (j.obj("texts") ?? [:]).compactMapValues { ($0 as? JSONObject).flatMap(Texts.init(json:)) }
        text_hashes = j["text_hashes"] as? [String: String] ?? [:]
        rtl = j.strs("rtl")
        aliases = j["aliases"] as? [String: String]
        providers = j["providers"] as? [String: [String]]
        hero = j.obj("hero").flatMap(HeroUi.init(json:))
        no_panel = j.bool("no_panel")
    }
}

final class HeroUi {
    /// `image` or `video`.
    var type: String
    var poster: [HeroSource]
    var video: [HeroSource]?
    var focal: [Double]?
    /// `crop` or `hide` (no media on phones).
    var phone: String?
    /// `curve`, `angle` or `straight`.
    var edge: String?

    @_optimize(size) init?(json j: JSONObject) {
        guard let t = j.str("type") else { return nil }
        type = t
        poster = (j.objs("poster") ?? []).compactMap(HeroSource.init(json:))
        video = j.objs("video").map { $0.compactMap(HeroSource.init(json:)) }
        focal = (j["focal"] as? [NSNumber])?.map { $0.doubleValue }
        phone = j.str("phone")
        edge = j.str("edge")
    }
}

struct HeroSource {
    var url: String
    var type: String
    var w: Int

    @_optimize(size) init?(json j: JSONObject) {
        guard let u = j.str("url"), let t = j.str("type") else { return nil }
        url = u
        type = t
        w = j.int("w") ?? 0
    }
}

/// One language of a banner version.
struct Texts {
    var title: String
    var message: String
    var accept_all: String
    var reject_all: String
    var customize: String
    var save: String
    var close: String
    var preferences_title: String
    var preferences_intro: String
    var kicker: String?
    var hero_alt: String?
    var policy_url: String?
    var purposes: [String: PurposeTexts]

    @_optimize(size) init?(json j: JSONObject) {
        guard let title = j.str("title"), let message = j.str("message"), let accept = j.str("accept_all"),
            let reject = j.str("reject_all")
        else { return nil }
        self.title = title
        self.message = message
        accept_all = accept
        reject_all = reject
        customize = j.str("customize") ?? ""
        save = j.str("save") ?? ""
        close = j.str("close") ?? ""
        preferences_title = j.str("preferences_title") ?? ""
        preferences_intro = j.str("preferences_intro") ?? ""
        kicker = j.str("kicker")
        hero_alt = j.str("hero_alt")
        policy_url = j.str("policy_url")
        purposes = (j.obj("purposes") ?? [:]).compactMapValues { v in
            (v as? JSONObject).map { PurposeTexts(name: $0.str("name") ?? "", description: $0.str("description") ?? "") }
        }
    }
}

struct PurposeTexts {
    var name: String
    var description: String
}

/// `GET /cmp/{code}/texts-{banner_version_id}-{lang}.json`: a language that is not inlined (immutable).
struct LanguagePack {
    var lang: String
    var hash: String
    var texts: Texts

    @_optimize(size) init?(data: Data) {
        guard let j = JSON.object(data), let l = j.str("lang"), let h = j.str("hash"),
            let t = j.obj("texts").flatMap(Texts.init(json:))
        else { return nil }
        lang = l
        hash = h
        texts = t
    }
}

/// `GET /m/v1/cmp/sdks/{version}.json`: the classes whose presence means an SDK is linked (§3.14).
struct SDKCatalogue {
    var v: Int
    /// Key → iOS class names.
    var sdks: [(k: String, ios: [String])]

    @_optimize(size) init?(data: Data) {
        guard let j = JSON.object(data), let v = j.int("v"), let list = j.objs("sdks") else { return nil }
        self.v = v
        sdks = list.compactMap { e in e.str("k").map { ($0, e.strs("ios") ?? []) } }
    }
}
