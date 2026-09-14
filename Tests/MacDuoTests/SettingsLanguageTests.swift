import Testing
@testable import MacDuo

/// Regression cover for the Simplified Chinese panel coming out in English.
///
/// `swift build` writes the localization as `zh-hans.lproj` while a universal
/// build writes `zh-Hans.lproj`, and `Bundle` matches resource names
/// case-sensitively even on a case-insensitive filesystem. Looking the
/// directory up under a fixed casing worked in a development build and fell
/// back to English in every released one.
struct SettingsLanguageTests {

    @Test func matchesTheCasingAUniversalBuildWrites() {
        #expect(
            SettingsLanguage.localizationName(matching: "zh-Hans", in: ["en", "zh-Hans"]) == "zh-Hans"
        )
    }

    @Test func matchesTheCasingAPlainBuildWrites() {
        #expect(
            SettingsLanguage.localizationName(matching: "zh-Hans", in: ["en", "zh-hans"]) == "zh-hans"
        )
    }

    @Test func everyOfferedLanguageResolvesInBothBuildLayouts() {
        for language in SettingsLanguage.allCases {
            #expect(
                SettingsLanguage.localizationName(matching: language.rawValue, in: ["en", "zh-hans"]) != nil,
                "\(language.rawValue) did not resolve in a plain build layout"
            )
            #expect(
                SettingsLanguage.localizationName(matching: language.rawValue, in: ["en", "zh-Hans"]) != nil,
                "\(language.rawValue) did not resolve in a universal build layout"
            )
        }
    }

    @Test func reportsNothingWhenTheBundleCarriesNoSuchTranslation() {
        #expect(SettingsLanguage.localizationName(matching: "zh-Hans", in: ["en"]) == nil)
    }
}
