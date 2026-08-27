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
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: now),
            to: calendar.startOfDay(for: expiryDate)
        ).day ?? 0

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

/// Home's meal-prep surface. Stands in the recommendation slot rather than
/// adding a section, exactly like `HomeQuickMealSection`, so the page keeps its
/// 今日计划 → 推荐位 → 库存待处理 shape.
struct HomeMealPrepBoardSection: View {
    let entries: [MealPrepBoardEntry]
    let onAdd: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("本周备餐")
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("home.mealPrep.section")

            VStack(alignment: .leading, spacing: 12) {
                if entries.isEmpty {
                    Text("还没有备餐")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("home.mealPrep.empty")
                } else {
                    ForEach(entries) { entry in
                        Text(entry.summary)
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("home.mealPrep.entry.\(entry.id.uuidString)")
                    }
                }

                // Goes to the existing management page; this board never grows
                // its own editor.
                Button(action: onAdd) {
                    HStack(spacing: 4) {
                        Text("添加备餐")
                        Image(systemName: "chevron.right")
                            .font(.footnote)
                            .dynamicTypeSize(...ChromeMetrics.symbolTypeLimit)
                    }
                    .font(.subheadline.weight(.medium))
                    .frame(minHeight: AppTheme.minimumHitTarget)
                    .contentShape(Rectangle())
                }
                    .foregroundStyle(AppTheme.brand)
                    .buttonStyle(.plain)
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
