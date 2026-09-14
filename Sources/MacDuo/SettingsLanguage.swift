import Foundation

/// The panel language is independent of effect settings and survives Reset.
enum SettingsLanguage: String, CaseIterable {
    case english = "en"
    case chinese = "zh-Hans"

    static var preferred: Self {
        Bundle.preferredLocalizations(from: ["en", "zh-Hans"])
            .first == "zh-Hans" ? .chinese : .english
    }

    // Packaged apps keep resources in Contents/Resources; SwiftPM's generated
    // accessor only searches the app root and the original build directory.
    private static var resources: Bundle {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("MacDuo_MacDuo.bundle"),
           let bundle = Bundle(url: url) { return bundle }
        return Bundle.module
    }

    /// The bundle's own spelling of this localization, or `nil` when it carries
    /// no such translation.
    ///
    /// A plain `swift build` writes `zh-hans.lproj` while a universal build
    /// writes `zh-Hans.lproj`, and `Bundle` matches resource names
    /// case-sensitively even where the filesystem does not. Looking the
    /// directory up under a guessed casing therefore works in a development
    /// build and returns nothing in the shipped app.
    static func localizationName(matching code: String, in available: [String]) -> String? {
        available.first { $0.caseInsensitiveCompare(code) == .orderedSame }
    }

    private var bundle: Bundle {
        let resources = Self.resources
        guard let name = Self.localizationName(matching: rawValue, in: resources.localizations),
              let path = resources.path(forResource: name, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return resources }
        return bundle
    }

    func localized(_ key: String) -> String {
        bundle.localizedString(forKey: key, value: key, table: nil)
    }
}
