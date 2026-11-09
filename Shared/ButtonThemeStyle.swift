import SwiftUI

extension ButtonTheme {
    /// Control tint is separate from QuoteRed / QuoteGreen and never feeds QuoteColor.
    var color: Color {
        switch self {
        case .teal: Color("AccentColor", bundle: .main)
        case .blue: Color("ButtonBlue", bundle: .main)
        case .purple: Color("ButtonPurple", bundle: .main)
        case .orange: Color("ButtonOrange", bundle: .main)
        case .pink: Color("ButtonPink", bundle: .main)
        case .graphite: Color("ButtonGraphite", bundle: .main)
        }
    }
}
