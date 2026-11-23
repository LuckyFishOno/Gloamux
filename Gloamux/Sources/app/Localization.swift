import Foundation
import os

// Interface text follows the standard Apple layout: `Resources/<language>.lproj/Localizable.strings`, keyed by the
// English source string, with English as the development language. The language choice is the app's own
// `AppleLanguages` preference, the same setting as System Settings › General › Language & Region › Applications, so
// either place changes it. Gloamux's own text switches at once; menus drawn by macOS follow after a restart.

/// The languages Gloamux ships, plus following the Mac.
public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system, traditionalChinese = "zh-Hant", simplifiedChinese = "zh-Hans"
    case english = "en", japanese = "ja", spanish = "es"
    public var id: String { rawValue }

    /// Localizations in `Resources`, in order of preference when nothing else matches.
    static let supported = allCases.filter { $0 != .system }.map(\.rawValue)

    /// Each language is named in itself, so anyone can find their own.
    public var title: String {
        switch self {
        case .system: return T("System default")
        case .english: return "English"
        case .traditionalChinese: return "\u{7e41}\u{9ad4}\u{4e2d}\u{6587}"
        case .simplifiedChinese: return "\u{7b80}\u{4f53}\u{4e2d}\u{6587}"
        case .japanese: return "\u{65e5}\u{672c}\u{8a9e}"
        case .spanish: return "Espa\u{f1}ol"
        }
    }

    /// The name of a resolved language code, in that language.
    static func title(for code: String) -> String {
        (AppLanguage(rawValue: code) ?? .english).title
    }

    /// The shipped language for a language tag such as `zh-TW`, `zh-Hans-CN`, `ja-JP`, or `es-419`, or nil when
    /// Gloamux has none. Chinese written in Taiwan, Hong Kong, and Macau uses Traditional characters; other Chinese,
    /// with no script or region, uses Simplified.
    static func matching(_ tag: String) -> AppLanguage? {
        let parts = tag.lowercased().replacingOccurrences(of: "_", with: "-").split(separator: "-").map(String.init)
        switch parts.first {
        case "en": return .english
        case "ja": return .japanese
        case "es": return .spanish
        case "zh":
            let rest = Set(parts.dropFirst())
            if rest.contains("hant") { return .traditionalChinese }
            if rest.contains("hans") { return .simplifiedChinese }
            return rest.isDisjoint(with: ["tw", "hk", "mo"]) ? .simplifiedChinese : .traditionalChinese
        default: return nil
        }
    }

    /// The shipped localization to use. Following the Mac takes the first preferred language Gloamux has, and
    /// anything else uses English.
    public func resolved(preferred: [String] = UIStrings.systemLanguages()) -> String {
        guard self == .system else { return rawValue }
        return preferred.lazy.compactMap(AppLanguage.matching).first?.rawValue ?? "en"
    }

    /// The language a stored `AppleLanguages` list asks for, or `.system` when it is absent.
    static func from(appleLanguages: [String]?) -> AppLanguage {
        appleLanguages?.first.flatMap(AppLanguage.matching) ?? .system
    }
}

// UI state is changed only from the application's main actor.
public enum UIStrings {
    public static func text(_ key: String) -> String { text(key, language: language) }

    private static let appleLanguages = "AppleLanguages"
    /// The key earlier versions stored the choice under; read once and moved to `AppleLanguages`.
    private static let legacyKey = "Gloamux.language"

    static var language: AppLanguage = {
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "--language"), index + 1 < args.count, let language = AppLanguage(rawValue: args[index + 1]) {
            return language
        }
        if let legacy = UserDefaults.standard.string(forKey: legacyKey) {
            let language = AppLanguage(rawValue: legacy) ?? AppLanguage.matching(legacy) ?? .system
            UserDefaults.standard.removeObject(forKey: legacyKey)
            store(language)
            return language
        }
        return AppLanguage.from(appleLanguages: appLanguages())
    }()

    /// Saves the choice as this app's preferred language, or removes it to follow the Mac. Only the app bundle writes
    /// it, so tests and command-line runs leave the user's setting alone.
    static func store(_ language: AppLanguage) {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        if language == .system { UserDefaults.standard.removeObject(forKey: appleLanguages) }
        else { UserDefaults.standard.set([language.rawValue], forKey: appleLanguages) }
    }

    /// `AppleLanguages` set for this app alone, not inherited from the Mac.
    private static func appLanguages() -> [String]? {
        CFPreferencesCopyValue(appleLanguages as CFString, kCFPreferencesCurrentApplication, kCFPreferencesCurrentUser,
                               kCFPreferencesAnyHost) as? [String]
    }

    /// The Mac's preferred languages, ignoring this app's own choice.
    public static func systemLanguages() -> [String] {
        CFPreferencesCopyValue(appleLanguages as CFString, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser,
                               kCFPreferencesAnyHost) as? [String] ?? Locale.preferredLanguages
    }

    /// One `.lproj` bundle per shipped language, loaded once so lookups are safe from any thread.
    static let bundles: [String: Bundle] = Dictionary(uniqueKeysWithValues: AppLanguage.supported.map { code in
        let path = Bundle.module.path(forResource: code, ofType: "lproj") ?? Bundle.module.path(forResource: code.lowercased(), ofType: "lproj")
        return (code, path.flatMap(Bundle.init(path:)) ?? Bundle.module)
    })

    private static let missing = "\u{1}"

    /// The translation of `key`, or nil when the language has none.
    static func lookup(_ key: String, in code: String) -> String? {
        let value = bundles[code]?.localizedString(forKey: key, value: missing, table: "Localizable")
        return value == missing ? nil : value
    }

    /// Interface text never ends with an ellipsis, in any language, even where a key keeps one or has no translation.
    static func withoutTrailingEllipsis(_ text: String) -> String {
        var result = Substring(text)
        while true {
            if result.hasSuffix("…") { result = result.dropLast() }
            else if result.hasSuffix("...") { result = result.dropLast(3) }
            else { break }
            while result.last == " " { result = result.dropLast() }
        }
        return String(result)
    }

    /// Translated text by language code and key. Views ask for the same strings on every redraw, and a bundle lookup
    /// each time was a large share of the main thread's work while the window redrew.
    private struct CacheKey: Hashable { let code: String; let key: String }
    private static let cache = OSAllocatedUnfairLock(initialState: [CacheKey: String]())
    /// Following the Mac reads its preferred languages; that is read again at most once a second, so a change in
    /// System Settings still shows up at once.
    private static let systemCode = OSAllocatedUnfairLock<(code: String, uptime: TimeInterval)?>(initialState: nil)

    static func code(for language: AppLanguage) -> String {
        guard language == .system else { return language.rawValue }
        let now = ProcessInfo.processInfo.systemUptime
        return systemCode.withLock { cached in
            if let cached, now - cached.uptime < 1 { return cached.code }
            let code = language.resolved()
            cached = (code, now)
            return code
        }
    }

    public static func text(_ key: String, language: AppLanguage) -> String {
        let cacheKey = CacheKey(code: code(for: language), key: key)
        if let text = cache.withLock({ $0[cacheKey] }) { return text }
        let text = withoutTrailingEllipsis(translated(key, code: cacheKey.code))
        cache.withLock { cache in
            // Messages with details in them are keys too; start over rather than grow without end.
            if cache.count > 5000 { cache.removeAll(keepingCapacity: true) }
            cache[cacheKey] = text
        }
        return text
    }

    private static func translated(_ key: String, code: String) -> String {
        if let translated = lookup(key, in: code) { return translated }
        // Error messages are built from a translated lead-in and a translated detail.
        for prefix in ["Connection failed: ", "Command failed: ", "Invalid connection settings: ", "The HTTP proxy refused the connection: "] {
            if key.hasPrefix(prefix), let translated = lookup(prefix, in: code) {
                return translated + Self.translated(String(key.dropFirst(prefix.count)), code: code)
            }
        }
        return key
    }
}

func T(_ key: String) -> String { UIStrings.text(key, language: UIStrings.language) }
