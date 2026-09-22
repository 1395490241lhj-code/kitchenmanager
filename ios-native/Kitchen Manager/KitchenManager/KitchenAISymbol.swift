/// The Kitchen AI identity symbol.
///
/// `emblem` means only "this feature or action is Kitchen AI": an explicit AI
/// entry point or an action that asks Kitchen AI to create something. It is
/// static (no symbol effect) and inherits the host surface's color.
///
/// It never means recommendation or discovery, recognition or OCR, loading,
/// provenance, an empty state, or a field hint — those keep their own symbols
/// or none. Active AI work is `KitchenAIStatus`, not this symbol.
nonisolated enum KitchenAISymbol {
    static let emblem = "sparkles"
}
