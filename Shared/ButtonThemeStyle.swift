import SwiftUI

extension ButtonTheme {
    /// Button tint is separate from QuoteRed / QuoteGreen and never feeds QuoteColor.
    var color: Color {
        switch self {
        case .teal: Color.accentColor
        case .blue: Color("ButtonBlue", bundle: .main)
        case .purple: Color("ButtonPurple", bundle: .main)
        case .orange: Color("ButtonOrange", bundle: .main)
        case .pink: Color("ButtonPink", bundle: .main)
        case .graphite: Color("ButtonGraphite", bundle: .main)
        }
    }
}
