import AppKit
import Testing
@testable import DevBox

@Test func systemThemeRemovesAppearanceOverride() {
    #expect(AppTheme.system.appearance == nil)
}

@Test func explicitThemesUseNativeAppearances() {
    #expect(AppTheme.light.appearance?.name == .aqua)
    #expect(AppTheme.dark.appearance?.name == .darkAqua)
}

@Test(arguments: AppTheme.allCases)
func themePreferenceRoundTrips(theme: AppTheme) {
    #expect(AppTheme(rawValue: theme.rawValue) == theme)
    #expect(!theme.title.isEmpty)
}
