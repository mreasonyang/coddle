import Foundation
import Combine

/// Runtime-switchable localization.
///
/// `.lproj` folders are copied into `Coddle.app/Contents/Resources` by
/// `build.sh`. Because `Bundle.main`'s preferred localization is fixed at
/// launch by the OS, the override is resolved through an *explicit* per-language
/// `Bundle` selected from config. Missing keys fall back to English, then to the
/// key itself — never blank, never a crash.
final class Localizer: ObservableObject {
    static let shared = Localizer(language: "system")

    /// Language codes that ship a `.lproj` bundle.
    static let supported = ["en", "zh-Hans", "zh-Hant", "ja", "ko", "es"]

    /// Current selection: "system" or one of `supported`.
    @Published var language: String = "system" {
        didSet { reload() }
    }

    private var active: Bundle = .main
    private var english: Bundle = .main
    private let resourceBundle: Bundle

    /// Sentinel `localizedString` returns when the active bundle has no entry;
    /// compared against so a translation that equals the key is still honoured.
    static let missingSentinel = "\u{0}__coddle_missing__"

    /// Explicit resources let isolated UI tests exercise the real localizer
    /// without reading the user's configuration or requiring the app singleton.
    init(language: String, resourceBundle: Bundle = .main) {
        // Property observers do not fire during initialization, so call reload()
        // explicitly after applying the persisted choice.
        self.resourceBundle = resourceBundle
        self.language = language
        reload()
    }

    /// Map a preference list onto a supported language code, with
    /// Traditional-Chinese disambiguation. Pure, so it can be tested without
    /// depending on the host's `Locale.preferredLanguages`.
    ///
    /// The first preferred language that maps to a supported code wins; any
    /// `zh-Hant*` / `zh-TW` / `zh-HK` resolves to `zh-Hant`, other `zh*` to
    /// `zh-Hans`. Falls back to `en`.
    static func resolve(
        systemPreferredLanguages: [String],
        supported: [String] = Localizer.supported
    ) -> String {
        for pref in systemPreferredLanguages {
            if pref.hasPrefix("zh-Hant") || pref.hasPrefix("zh-TW") || pref.hasPrefix("zh-HK") {
                return "zh-Hant"
            }
            if pref.hasPrefix("zh") { return "zh-Hans" }
            for code in supported where pref.hasPrefix(code) { return code }
        }
        return "en"
    }

    /// Map "system" (or an unsupported code) onto a supported language using the
    /// OS's preferred languages.
    static func resolve(_ lang: String) -> String {
        if lang != "system", supported.contains(lang) { return lang }
        return resolve(systemPreferredLanguages: Locale.preferredLanguages)
    }

    /// Exact bundle for a language code, e.g. "zh-Hans".
    static func bundle(for code: String, in resourceBundle: Bundle = .main) -> Bundle? {
        guard let path = resourceBundle.path(forResource: code, ofType: "lproj") else { return nil }
        return Bundle(path: path)
    }

    private func reload() {
        active = Localizer.bundle(for: Localizer.resolve(language), in: resourceBundle) ?? resourceBundle
        english = Localizer.bundle(for: "en", in: resourceBundle) ?? resourceBundle
    }

    /// Pure fallback chain: the active language's value, else English, else the
    /// key itself. `active` is `missingSentinel` when the active bundle has no
    /// entry; `english` is expected to default to the key when absent.
    static func resolveValue(active: String, english: String) -> String {
        active != missingSentinel ? active : english
    }

    /// Pure `{n}` substitution, in argument order. Successive placeholders are
    /// filled by successive args; once no `{n}` remains, extra args are ignored.
    static func format(_ template: String, args: [CVarArg]) -> String {
        var s = template
        for a in args {
            let value: String
            if let i = a as? Int { value = String(i) }
            else if let i64 = a as? Int64 { value = String(i64) }
            else if let d = a as? Double { value = String(d) }
            else { value = "\(a)" }
            if let r = s.range(of: "{n}") { s.replaceSubrange(r, with: value) }
        }
        return s
    }

    /// Translate a key: active language -> English -> the key itself.
    func tr(_ key: String) -> String {
        let a = active.localizedString(forKey: key, value: Localizer.missingSentinel, table: nil)
        let e = english.localizedString(forKey: key, value: key, table: nil)
        return Localizer.resolveValue(active: a, english: e)
    }

    /// Translate a key and substitute `{n}` placeholders in argument order.
    /// (Strings use `{n}` rather than printf verbs so `%` stays literal.)
    func tr(_ key: String, _ args: CVarArg...) -> String {
        Localizer.format(tr(key), args: args)
    }
}
