import SwiftUI

// MARK: - Home summary line

/// The compact, secondary line Home shows under its date: today's effective
/// `DayType`, plus any meal that is an exception to it. Deliberately not a card
/// and not a dashboard section — it lives inside the existing header block, so
/// Home's section order is unchanged.
///
/// Takes plain values rather than reading the store, so previews (and Home's own
/// header previews) can render it without an environment object.
struct HomeDayRhythmRow: View {
    let dayType: DayType
    /// Only the meals that differ from the default. `household` is the norm and
    /// is never spelled out here.
    let eatOutSlots: [MealSlot]
    /// Ready-made portion/carryover phrases, already ordered by the caller.
    /// These are shown alongside an eat-out meal rather than instead of it: a
    /// portion already set aside is food that exists, and marking the meal as
    /// eating out must never make it invisible.
    var portionSummaries: [String] = []
    let action: () -> Void

    private var summaryText: String {
        ([dayType.homeSummaryTitle] + eatOutSlots.map(\.eatOutSummary) + portionSummaries)
            .joined(separator: " · ")
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(summaryText)
                    .multilineTextAlignment(.leading)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                Spacer(minLength: 0)
            }
            .font(.footnote)
            // Deliberately uncapped: the summary follows the full Dynamic Type
            // range and is allowed to wrap at Accessibility sizes, pushing the
            // rest of Home down. Keeping every word legible outranks keeping the
            // Today Plan card on the first screen at those sizes.
            .foregroundStyle(.secondary)
            .frame(minHeight: AppTheme.minimumHitTarget, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("今天：\(summaryText)")
        .accessibilityHint("查看并调整今天的用餐安排")
        .accessibilityIdentifier("home.dayRhythm.row")
    }
}

// MARK: - Today sheet

/// Home's "今天怎么安排" sheet. Every control is a native Form picker, matching
/// the Settings form the app already uses, so it inherits Dynamic Type, dark
/// mode and VoiceOver behaviour instead of introducing a new visual language.
struct TodayRhythmSheet: View {
    @EnvironmentObject private var dayRhythmStore: DayRhythmStore
    @EnvironmentObject private var mealPortionStore: MealPortionStore
    @Environment(\.dismiss) private var dismiss

    private var dinnerPlan: MealPortionPlan { mealPortionStore.portionPlan(slot: .dinner) }
    private var incomingLunch: CarryoverReservation? {
        mealPortionStore.incomingReservation(slot: .lunch)
    }

    private var canRestoreDefaults: Bool {
        dayRhythmStore.isTodayCustomized || !dinnerPlan.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("今日节奏", selection: dayTypeBinding) {
                        ForEach(DayType.allCases, id: \.self) { type in
                            Text(type.title).tag(type)
                        }
                    }
                    .frame(minHeight: ChromeMetrics.minimumRowHeight)
                    .accessibilityIdentifier("today.rhythm.dayType.picker")
                } footer: {
                    // Low emphasis, and only while today actually departs from
                    // the weekly plan — otherwise it just restates the picker.
                    if dayRhythmStore.isTodayOverridden {
                        Text("每\(dayRhythmStore.todayWeekday.title)默认：\(dayRhythmStore.todayWeeklyDefault.title)")
                            .accessibilityIdentifier("today.rhythm.weeklyDefault.footer")
                    }
                }

                Section("用餐") {
                    intentPicker(for: .lunch)
                    // Shown whatever the lunch intent is: food set aside last
                    // night still exists even if today's lunch is eaten out.
                    if let incomingLunch {
                        incomingReservationRow(incomingLunch)
                    }
                    intentPicker(for: .dinner)
                }

                Section {
                    Stepper(value: currentDinnerPortionsBinding, in: 0...12) {
                        LabeledContent(
                            "今晚吃",
                            value: MealPortionCopy.currentMeal(dinnerPlan.currentMealPortions)
                        )
                    }
                    .frame(minHeight: ChromeMetrics.minimumRowHeight)
                    .accessibilityIdentifier("today.portions.current.stepper")

                    Stepper(value: reservedPortionsBinding, in: 0...12) {
                        LabeledContent(
                            "明天午餐留",
                            value: MealPortionCopy.reserved(dinnerPlan.reservedForNextLunchPortions)
                        )
                    }
                    .frame(minHeight: ChromeMetrics.minimumRowHeight)
                    .accessibilityIdentifier("today.portions.reserved.stepper")

                    LabeledContent(
                        "共需做",
                        value: MealPortionCopy.total(dinnerPlan.totalPlannedPortions)
                    )
                    .frame(minHeight: ChromeMetrics.minimumRowHeight)
                    .accessibilityIdentifier("today.portions.total.row")
                } header: {
                    Text("晚餐份量")
                } footer: {
                    Text("份量只用于记录安排，不参与买菜和库存计算。")
                }

                if canRestoreDefaults {
                    Section {
                        Button("恢复今天默认安排") {
                            dayRhythmStore.resetToday()
                            mealPortionStore.resetPortions()
                        }
                        .foregroundStyle(AppTheme.brand)
                        .frame(minHeight: ChromeMetrics.minimumRowHeight)
                        .accessibilityIdentifier("today.rhythm.reset.button")
                    } footer: {
                        Text("恢复后，今天回到本周默认节奏，两餐回到照常，今晚的份量安排也一并清除。昨晚留给今天的份数不受影响。")
                    }
                }
            }
            .navigationTitle("今天怎么安排")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                        .accessibilityIdentifier("today.rhythm.done.button")
                }
            }
        }
    }

    private func incomingReservationRow(_ reservation: CarryoverReservation) -> some View {
        HStack {
            Text(MealPortionCopy.targetDayRow(reservation.portions))
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            // All or nothing: editing down to "half a portion left" is leftovers
            // semantics and deliberately out of scope.
            Button("取消") {
                mealPortionStore.cancelIncomingReservation(slot: .lunch)
            }
            .foregroundStyle(AppTheme.brand)
        }
        .frame(minHeight: ChromeMetrics.minimumRowHeight)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("today.portions.incoming.row")
    }

    private func intentPicker(for slot: MealSlot) -> some View {
        Picker(slot.title, selection: intentBinding(for: slot)) {
            ForEach([MealIntent.household, .eatOut], id: \.self) { intent in
                Text(intent.title).tag(intent)
            }
        }
        .frame(minHeight: ChromeMetrics.minimumRowHeight)
        .accessibilityIdentifier("today.rhythm.\(slot.rawValue).picker")
    }

    /// Picking the weekly default clears the override instead of storing a
    /// duplicate of it, so "today is just a normal 周三" never persists as a
    /// custom day.
    private var dayTypeBinding: Binding<DayType> {
        Binding(
            get: { dayRhythmStore.effectiveDayType() },
            set: { selected in
                if selected == dayRhythmStore.todayWeeklyDefault {
                    dayRhythmStore.clearTodayOverride()
                } else {
                    dayRhythmStore.overrideToday(with: selected)
                }
            }
        )
    }

    private func intentBinding(for slot: MealSlot) -> Binding<MealIntent> {
        Binding(
            get: { dayRhythmStore.intent(for: slot) },
            set: { dayRhythmStore.setIntent($0, for: slot) }
        )
    }

    /// The stepper works in plain `Int` and uses 0 as its floor, but 0 is only a
    /// transport value: the store turns it back into "unset" rather than storing
    /// a zero portion count.
    private var currentDinnerPortionsBinding: Binding<Int> {
        Binding(
            get: { dinnerPlan.currentMealPortions ?? 0 },
            set: { mealPortionStore.setCurrentMealPortions($0, slot: .dinner) }
        )
    }

    private var reservedPortionsBinding: Binding<Int> {
        Binding(
            get: { dinnerPlan.reservedForNextLunchPortions },
            set: { mealPortionStore.setReservedForNextLunchPortions($0) }
        )
    }
}

// MARK: - Weekly settings page

/// Settings → 每周用餐节奏. One row per weekday, Monday first, each a native
/// menu picker — the same control 显示模式 and 菜谱库模式 already use.
struct WeeklyRhythmSettingsView: View {
    @EnvironmentObject private var dayRhythmStore: DayRhythmStore

    var body: some View {
        Form {
            Section {
                ForEach(Weekday.displayOrder, id: \.self) { weekday in
                    Picker(weekday.title, selection: binding(for: weekday)) {
                        ForEach(DayType.allCases, id: \.self) { type in
                            Text(type.title).tag(type)
                        }
                    }
                    .frame(minHeight: ChromeMetrics.minimumRowHeight)
                    .accessibilityIdentifier("settings.weeklyRhythm.\(weekday.rawValue).picker")
                }
            } footer: {
                Text("这是每周的默认安排。今天临时改动只影响当天，不会修改这里。")
            }
        }
        .navigationTitle("每周用餐节奏")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            Color.clear
                .frame(height: ChromeMetrics.bottomClearance)
                .accessibilityHidden(true)
        }
    }

    private func binding(for weekday: Weekday) -> Binding<DayType> {
        Binding(
            get: { dayRhythmStore.weeklyDefault(for: weekday) },
            set: { dayRhythmStore.setWeeklyDefault($0, for: weekday) }
        )
    }
}

// MARK: - Previews

@MainActor
private func previewStore(
    weeklyDefaults: [Weekday: DayType] = [:],
    override: DayType? = nil,
    eatOut: [MealSlot] = []
) -> DayRhythmStore {
    let store = DayRhythmStore(
        userDefaults: UserDefaults(suiteName: "preview.dayRhythm.\(UUID().uuidString)")!
    )
    for (weekday, type) in weeklyDefaults {
        store.setWeeklyDefault(type, for: weekday)
    }
    if let override { store.overrideToday(with: override) }
    for slot in eatOut { store.setIntent(.eatOut, for: slot) }
    return store
}

@MainActor
private func previewPortionStore(
    currentDinner: Int? = nil,
    reservedForTomorrow: Int = 0,
    incomingLunch: Int = 0
) -> MealPortionStore {
    let store = MealPortionStore(
        userDefaults: UserDefaults(suiteName: "preview.mealPortion.\(UUID().uuidString)")!
    )
    if let currentDinner { store.setCurrentMealPortions(currentDinner, slot: .dinner) }
    if reservedForTomorrow > 0 { store.setReservedForNextLunchPortions(reservedForTomorrow) }
    if incomingLunch > 0 {
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        store.setReservedForNextLunchPortions(incomingLunch, from: yesterday)
    }
    return store
}

#Preview("首页节奏行 — 默认") {
    HomeDayRhythmRow(dayType: .flexible, eatOutSlots: [], action: {})
        .padding()
        .background(Color(.systemGroupedBackground))
}

#Preview("首页节奏行 — 两餐外食") {
    HomeDayRhythmRow(dayType: .cooking, eatOutSlots: [.lunch, .dinner], action: {})
        .padding()
        .background(Color(.systemGroupedBackground))
}

#Preview("首页节奏行 — 留一份明日午餐") {
    HomeDayRhythmRow(
        dayType: .cooking,
        eatOutSlots: [],
        portionSummaries: [MealPortionCopy.sourceDaySummary(1)],
        action: {}
    )
    .padding()
    .background(Color(.systemGroupedBackground))
}

#Preview("首页节奏行 — 外食 + 已留份数") {
    HomeDayRhythmRow(
        dayType: .flexible,
        eatOutSlots: [.lunch],
        portionSummaries: [MealPortionCopy.targetDaySummary(1)],
        action: {}
    )
    .padding()
    .background(Color(.systemGroupedBackground))
}

#Preview("首页节奏行 — 大字号") {
    HomeDayRhythmRow(
        dayType: .mealPrep,
        eatOutSlots: [.lunch],
        portionSummaries: [MealPortionCopy.targetDaySummary(1), MealPortionCopy.sourceDaySummary(2)],
        action: {}
    )
    .padding()
    .background(Color(.systemGroupedBackground))
    .dynamicTypeSize(.accessibility3)
}

#Preview("今天怎么安排") {
    TodayRhythmSheet()
        .environmentObject(previewStore(weeklyDefaults: [.wednesday: .cooking], override: .quick, eatOut: [.lunch]))
        .environmentObject(previewPortionStore(currentDinner: 2, reservedForTomorrow: 1, incomingLunch: 1))
}

#Preview("今天怎么安排 — 份量未设置") {
    TodayRhythmSheet()
        .environmentObject(previewStore())
        .environmentObject(previewPortionStore())
}

#Preview("今天怎么安排 — 深色") {
    TodayRhythmSheet()
        .environmentObject(previewStore())
        .environmentObject(previewPortionStore(currentDinner: 2, reservedForTomorrow: 1))
        .preferredColorScheme(.dark)
}

#Preview("今天怎么安排 — 大字号") {
    TodayRhythmSheet()
        .environmentObject(previewStore(eatOut: [.lunch]))
        .environmentObject(previewPortionStore(currentDinner: 2, reservedForTomorrow: 1, incomingLunch: 1))
        .dynamicTypeSize(.accessibility3)
}

#Preview("每周用餐节奏") {
    NavigationStack {
        WeeklyRhythmSettingsView()
            .environmentObject(previewStore(weeklyDefaults: [.monday: .quick, .saturday: .cooking]))
    }
}
