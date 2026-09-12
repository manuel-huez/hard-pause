import CoreText
import SwiftUI

#if os(iOS)
    import UIKit
#endif

enum PauseTheme {
    static let background = Color(red: 28 / 255, green: 29 / 255, blue: 41 / 255)
    static let ink = Color(red: 236 / 255, green: 239 / 255, blue: 246 / 255)
    static let muted = Color(red: 183 / 255, green: 195 / 255, blue: 216 / 255)
    static let coral = Color(red: 200 / 255, green: 216 / 255, blue: 242 / 255)
    static let surface = Color(red: 37 / 255, green: 40 / 255, blue: 55 / 255)
    static let stroke = Color(red: 73 / 255, green: 83 / 255, blue: 107 / 255)
}

/// Recursive's casual and slope axes are part of the selected Low Light design.
/// Register locally on both platforms; iOS also declares the font in UIAppFonts.
enum PauseFont {
    private static let registered: Void = {
        #if os(macOS)
            if let url = Bundle.main.url(forResource: "Recursive", withExtension: "ttf") {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        #endif
    }()

    static func display(_ size: CGFloat, relativeTo style: Font.TextStyle = .title) -> Font {
        make(size, weight: 350, slope: -7, relativeTo: style)
    }

    static func body(_ size: CGFloat = 16, relativeTo style: Font.TextStyle = .body) -> Font {
        make(size, weight: 420, relativeTo: style)
    }

    static func mono(_ size: CGFloat, relativeTo style: Font.TextStyle = .title) -> Font {
        make(size, weight: 350, mono: 0.5, relativeTo: style)
    }

    private static func make(
        _ size: CGFloat, weight: Double, slope: Double = 0, mono: Double = 0,
        relativeTo style: Font.TextStyle
    ) -> Font {
        _ = registered
        let axes: [NSNumber: NSNumber] = [
            0x4341_534C: 1,  // CASL
            0x4D4F_4E4F: NSNumber(value: mono),
            0x7767_6874: NSNumber(value: weight),
            0x736C_6E74: NSNumber(value: slope),
        ]
        let descriptor = CTFontDescriptorCreateWithAttributes(
            [
                kCTFontNameAttribute: "RecursiveSansCsl-Regular",
                kCTFontVariationAttribute: axes,
            ] as CFDictionary)
        let font = CTFontCreateWithFontDescriptor(descriptor, size, nil)
        #if os(iOS)
            let textStyle: UIFont.TextStyle
            switch style {
            case .largeTitle: textStyle = .largeTitle
            case .title: textStyle = .title1
            case .title2: textStyle = .title2
            case .title3: textStyle = .title3
            case .headline: textStyle = .headline
            case .subheadline: textStyle = .subheadline
            case .footnote: textStyle = .footnote
            case .caption: textStyle = .caption1
            case .caption2: textStyle = .caption2
            default: textStyle = .body
            }
            return Font(UIFontMetrics(forTextStyle: textStyle).scaledFont(for: font as UIFont))
        #else
            return Font(font)
        #endif
    }
}

struct PauseCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PauseTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(PauseTheme.stroke.opacity(0.55), lineWidth: 1)
            }
    }
}
