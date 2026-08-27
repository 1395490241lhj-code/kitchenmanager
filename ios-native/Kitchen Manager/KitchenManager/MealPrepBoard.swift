import SwiftUI

// MARK: - Meal prep day on Home (P1-F)
//
// A 备餐日 is a *production* day: the household is making portions for the days
// ahead. `DayType`'s axis is how much cooking is planned, not what shape dinner
// takes, so this slot answers "what did I put by, and what needs eating first"
// rather than proposing a meal.
//
// Everything here reads existing `PreparedComponent` records. There is no prep
// plan model and this phase does not invent one: the app records what was made,
// which is a different (and cheaper) claim than planning what to make.

/// One line of the board.
struct MealPrepBoardEntry: Equatable, Identifiable {
    let id: UUID
    let name: String
    let portionsText: String
    let expiryText: String

    /// "卤鸡腿 · 剩 3 份 · 建议明天前吃完"
    var summary: String { "\(name) · \(portionsText) · \(expiryText)" }
}

enum MealPrepBoard {
    /// Soonest to finish first. Ties fall back to when the batch was made and
    /// then to a stable key, so the same set of batches always draws in the
    /// same order — including two made on the same day with the same date.
    static func entries(
        from components: [PreparedComponent],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [MealPrepBoardEntry] {
        components
            .sorted { lhs, rhs in
                if lhs.expiryDate != rhs.expiryDate { return lhs.expiryDate < rhs.expiryDate }
                if lhs.preparedAt != rhs.preparedAt { return lhs.preparedAt < rhs.preparedAt }
                if lhs.name != rhs.name {
                    return lhs.name.localizedCompare(rhs.name) == .orderedAscending
                }
                return lhs.id.uuidString < rhs.id.uuidString
            }
            .map { component in
                MealPrepBoardEntry(
                    id: component.id,
                    name: component.name,
                    portionsText: component.portionsText,
                    expiryText: expiryText(for: component.expiryDate, now: now, calendar: calendar)
                )
            }
    }

    /// Relative wording only where a person would use it, an ordinary date
    /// otherwise.
    ///
    /// The phrasing stays 建议…吃完 in every branch: this is the user's own note
    /// about when they mean to finish a batch, seeded from a conservative
    /// starting point. It is not a food-safety guarantee and must never read
    /// like one.
    static func expiryText(
        for expiryDate: Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        // Shared with Home's urgency policy so "how many days are left" has one
        // implementation. This function only *phrases* the answer; whether that
        // number is urgent enough for Home is
        // `PreparedComponentExpiryPolicy.isUrgentForHomeAttention`, and the
        // board deliberately does not consult it — a 备餐日 lists every batch.
        let days = PreparedComponentExpiryPolicy.daysRemaining(
            until: expiryDate, now: now, calendar: calendar
        )

        switch days {
        case ..<0: return "建议尽快吃完"
        case 0: return "建议今天吃完"
        case 1: return "建议明天前吃完"
        default: return "建议 \(dateText(for: expiryDate, calendar: calendar)) 前吃完"
        }
    }

    /// Pinned to zh_Hans_CN like `HomeDatePresentation`, so the row reads
    /// "8月31日" rather than "Aug 31" beside Home's own Chinese date line.
    /// `.formatted(.dateTime…)` follows the device locale and produced the
    /// English form on an English simulator.
    static func dateText(for date: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "M月d日"
        return formatter.string(from: date)
    }
}

/// Home's meal-prep content.
///
/// Home V2: the title moved out (`HomePrimaryHeader` says 今天备的菜 · 先吃快到期的),
/// each batch became a real row instead of one concatenated line, and 添加备餐
/// became the prep day's one prominent action — a production day previously had
/// no primary action at all. It still only records what was made: there is no
/// prep plan here and this phase does not invent one.
struct HomeMealPrepBoardSection: View {
    let entries: [MealPrepBoardEntry]
    let onAdd: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(spacing: 0) {
                if entries.isEmpty {
                    Text("还没有备餐")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: AppTheme.minimumHitTarget, alignment: .leading)
                        .accessibilityIdentifier("home.mealPrep.empty")
                } else {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.name).font(.headline)
                                Text(entry.expiryText)
                                    .font(.footnote)
                                    // Only the batch that is actually next gets
                                    // the warning ink; the rest stay neutral so
                                    // "soonest" remains readable at a glance.
                                    .foregroundStyle(index == 0 ? AppTheme.warningInk : AppTheme.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 8)
                            Text(entry.portionsText)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: AppTheme.minimumHitTarget, alignment: .leading)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(entry.summary)
                        .accessibilityIdentifier("home.mealPrep.entry.\(entry.id.uuidString)")
                        if index < entries.count - 1 { Divider() }
                    }
                }
            }

            // Goes to the existing management page; this board never grows its
            // own editor.
            Button("记一笔今天做的", action: onAdd)
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.cookingActionFill)
                .foregroundStyle(AppTheme.onCookingAction)
                .font(.subheadline.weight(.semibold))
                .controlSize(.regular)
                .buttonBorderShape(.capsule)
                .frame(minHeight: AppTheme.minimumHitTarget)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("home.mealPrep.add")
                .accessibilityHint("打开备餐记录")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: AppTheme.radiusCard, style: .continuous)
        )
    }
}

// MARK: - Previews

@MainActor
private func previewBatch(_ name: String, _ portions: Int, inDays days: Int) -> PreparedComponent {
    PreparedComponent(
        name: name, portionsRemaining: portions, state: .cooked, storage: .refrigerated,
        preparedAt: Date(),
        expiryDate: Calendar.current.date(byAdding: .day, value: days, to: Date()) ?? Date()
    )
}

#Preview("备餐日") {
    HomeMealPrepBoardSection(
        entries: MealPrepBoard.entries(from: [
            previewBatch("卤鸡腿", 3, inDays: 1),
            previewBatch("腌鸡肉", 2, inDays: 4)
        ]),
        onAdd: {}
    )
    .padding()
    .background(Color(.systemGroupedBackground))
}

#Preview("备餐日 — 空") {
    HomeMealPrepBoardSection(entries: [], onAdd: {})
        .padding()
        .background(Color(.systemGroupedBackground))
}
