import Foundation

/// Resolves a user-facing string in the app's current language.
///
/// The source language is Japanese. `en.lproj/Localizable.strings` supplies the
/// English translations, and Japanese falls back to the literal key. Strings
/// passed here must stay static so Xcode can extract them; interpolated values
/// become `%@` placeholders automatically.
@inline(__always)
func L(_ key: String.LocalizationValue) -> String {
    String(localized: key)
}

/// Resolves a key that is only known at runtime, such as a value from a
/// generated catalog. Prefer `L` for literals so Xcode can extract them.
@inline(__always)
func LKey(_ key: String) -> String {
    String(localized: String.LocalizationValue(key))
}
