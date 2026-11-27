import Foundation

/// The language Tackroom's text is shown in.
public enum AppLanguage {
    /// Choices for Settings, each named in its own language. `nil` follows macOS.
    public static let choices: [(code: String?, name: String)] = [
        (nil, L("跟隨系統")), ("zh-Hant", "繁體中文"), ("zh-Hans", "简体中文"), ("en", "English"),
    ]

    /// What the user picked, kept the way macOS keeps an app's language
    /// (it takes effect the next time Tackroom starts).
    public static var chosen: String? {
        get { (UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?["AppleLanguages"] as? [String])?.first }
        set {
            let defaults = UserDefaults.standard
            guard let newValue else {
                defaults.removeObject(forKey: "AppleLanguages")
                defaults.removeObject(forKey: "AppleLocale")
                return
            }
            defaults.set([newValue], forKey: "AppleLanguages")
            // Dates and plural forms follow the locale: same region as macOS, chosen language.
            let system = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleLocale"] as? String
            let region = system.flatMap { Locale(identifier: $0).region?.identifier }
            defaults.set(region.map { newValue + "_" + $0 } ?? newValue, forKey: "AppleLocale")
        }
    }

    /// The language this run uses, for plural forms and dates.
    public static let locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "zh-Hant")
}

/// Text shown to people, looked up in the app's Localizable.strings.
/// Traditional Chinese is the source language, so the key is the text itself
/// and anything without a translation (tests, the bare CLI) stays as written.
public func L(_ value: String.LocalizationValue) -> String { String(localized: value, locale: AppLanguage.locale) }
