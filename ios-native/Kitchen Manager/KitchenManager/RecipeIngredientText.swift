import SwiftUI

/// Keeps the exact scaled source suffix; unfamiliar formats stay as one line.
struct RecipeIngredientText: View {
    let text: String
    var body: some View {
        let name = IngredientParser.parse(text).displayName
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            if text.hasPrefix(name), text != name {
                Text(name).frame(maxWidth: .infinity, alignment: .leading)
                Text(String(text.dropFirst(name.count)).trimmingCharacters(in: .whitespaces))
                    .monospacedDigit().foregroundStyle(KitchenTheme.textSecondary)
                    .layoutPriority(1)
            } else {
                Text(text).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
