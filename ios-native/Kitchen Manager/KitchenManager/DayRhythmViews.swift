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
    let action: () -> Void

    private var summaryText: String {
        ([dayType.homeSummaryTitle] + eatOutSlots.map(\.eatOutSummary))
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
    @Environment(\.dismiss) private var dismiss

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
                    intentPicker(for: .dinner)
                }

                if dayRhythmStore.isTodayCustomized {
                    Section {
                        Button("恢复今天默认安排") {
                            dayRhythmStore.resetToday()
                        }
                        .foregroundStyle(AppTheme.brand)
                        .frame(minHeight: ChromeMetrics.minimumRowHeight)
                        .accessibilityIdentifier("today.rhythm.reset.button")
                    } footer: {
                        Text("恢复后，今天回到本周默认节奏，两餐也回到照常。")
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

#Preview("首页节奏行 — 大字号") {
    HomeDayRhythmRow(dayType: .mealPrep, eatOutSlots: [.lunch], action: {})
        .padding()
        .background(Color(.systemGroupedBackground))
        .dynamicTypeSize(.accessibility3)
}

#Preview("今天怎么安排") {
    TodayRhythmSheet()
        .environmentObject(previewStore(weeklyDefaults: [.wednesday: .cooking], override: .quick, eatOut: [.lunch]))
}

#Preview("今天怎么安排 — 深色") {
    TodayRhythmSheet()
        .environmentObject(previewStore())
        .preferredColorScheme(.dark)
}

#Preview("每周用餐节奏") {
    NavigationStack {
        WeeklyRhythmSettingsView()
            .environmentObject(previewStore(weeklyDefaults: [.monday: .quick, .saturday: .cooking]))
    }
}
