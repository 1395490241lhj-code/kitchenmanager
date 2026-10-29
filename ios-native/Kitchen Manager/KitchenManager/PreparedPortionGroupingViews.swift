import SwiftUI

struct PreparedSourceHeader: View {
    let section: PreparedSourceSection
    var body: some View {
        if let source = section.source {
            VStack(alignment: .leading, spacing: 4) {
                Text("第\(section.batchNumber ?? 1)批 · \(source.name)").font(.headline).foregroundStyle(.primary)
                Text("原记 \(PreparedMassInput.grams(source.initialMassDecigrams)) · \(source.initialPortionCount)份")
                if let remaining = section.remainingMassDecigrams {
                    Text("现剩 \(PreparedMassInput.grams(remaining)) · \(section.remainingPortionCount)份")
                } else { Text("剩余重量暂时无法计算，请重新读取") }
            }
            .font(.subheadline).textCase(nil)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("第\(section.batchNumber ?? 1)批，\(source.name)。原记\(PreparedMassInput.spoken(source.initialMassDecigrams))，\(source.initialPortionCount)份。现剩\(section.remainingMassDecigrams.map(PreparedMassInput.spoken) ?? "重量暂时无法计算")，\(section.remainingPortionCount)份。")
            .accessibilityIdentifier("prepared.source.\(source.id.uuidString)")
        }
    }
}

struct PreparedGroupedRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let component: PreparedComponent
    let groupLabel: String
    let onEdit: () -> Void
    let onConsume: () -> Void
    let onSplit: () -> Void
    let onLifecycle: (PreparedLifecycleAction) -> Void
    private var context: String { component.grouping == nil ? component.name : "\(component.name)，\(groupLabel)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: onEdit) {
                VStack(alignment: .leading, spacing: 4) {
                    if component.grouping != nil { Text(groupLabel).font(.caption).foregroundStyle(.secondary) }
                    if dynamicTypeSize.isAccessibilitySize {
                        name
                        Text(component.portionsText).font(.subheadline).foregroundStyle(.secondary)
                    } else {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            name
                            Spacer(minLength: 8)
                            Text(component.portionsText).font(.subheadline).foregroundStyle(.secondary).fixedSize()
                        }
                    }
                }
                .frame(maxWidth: .infinity, minHeight: AppTheme.minimumHitTarget, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("编辑\(context)，\(component.portionsText)")
            .accessibilityIdentifier("prepared.edit.\(component.id.uuidString)")
            if let grouping = component.grouping {
                Text("每份\(PreparedMassInput.grams(grouping.massPerPortionDecigrams))")
                    .font(.subheadline)
                    .accessibilityLabel("每份\(PreparedMassInput.spoken(grouping.massPerPortionDecigrams))")
                    .accessibilityIdentifier("prepared.mass.\(component.id.uuidString)")
            }
            Text(PreparedLifecyclePresentation.status(component)).font(.footnote).foregroundStyle(.secondary)
                .accessibilityIdentifier("prepared.status.\(component.id.uuidString)")
            Text("建议 \(MealPrepBoard.dateText(for: component.expiryDate)) 前吃完")
                .font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("prepared.expiry.\(component.id.uuidString)")
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) { actions }
            } else { HStack(spacing: 20) { actions } }
            ForEach(PreparedLifecyclePresentation.actions(for: component), id: \.key) { action in
                Button { onLifecycle(action) } label: {
                    Text(action.title).font(.subheadline.weight(.medium))
                        .frame(minWidth: AppTheme.minimumHitTarget, minHeight: AppTheme.minimumHitTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(AppTheme.brand)
                .accessibilityLabel("\(action.title)，\(context)，\(component.portionsRemaining)份")
                .accessibilityHint("操作整组；只处理部分份数请先分出整份")
                .accessibilityIdentifier("prepared.lifecycle.\(action.key).\(component.id.uuidString)")
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }
    private var name: some View {
        Text(component.name).font(.headline).foregroundStyle(.primary)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
            .fixedSize(horizontal: false, vertical: true)
    }
    @ViewBuilder private var actions: some View {
        Button(action: onConsume) {
            Text("吃掉一份").font(.subheadline.weight(.medium))
                .frame(minWidth: AppTheme.minimumHitTarget, minHeight: AppTheme.minimumHitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(AppTheme.brand)
        .accessibilityLabel("吃掉一份\(context)")
        .accessibilityIdentifier("prepared.consume.\(component.id.uuidString)")
        if component.grouping != nil, component.portionsRemaining > 1 {
            Button(action: onSplit) {
                Text("分出份数").font(.subheadline.weight(.medium))
                    .frame(minWidth: AppTheme.minimumHitTarget, minHeight: AppTheme.minimumHitTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(AppTheme.brand)
            .accessibilityLabel("分出整份，\(context)")
            .accessibilityIdentifier("prepared.split.\(component.id.uuidString)")
        }
    }
}

struct PreparedPortionSplitEditor: View {
    @EnvironmentObject private var store: KitchenStore
    @Environment(\.dismiss) private var dismiss
    @State private var expected: PreparedComponent
    @State private var taking = 1
    @State private var siblingID = UUID()
    @State private var saveError: PreparedComponentMutationError?
    @State private var hasSaveFailure = false
    let onSuccess: (Int) -> Void
    init(component: PreparedComponent, onSuccess: @escaping (Int) -> Void) {
        _expected = State(initialValue: component)
        self.onSuccess = onSuccess
    }
    private var isValid: Bool { (1..<max(1, expected.portionsRemaining)).contains(taking) && expected.grouping != nil }
    private var current: PreparedComponent? { store.preparedComponents.first { $0.id == expected.id } }
    var body: some View {
        NavigationStack {
            Form {
                if store.isPreparedComponentUnavailable { PreparedCollectionUnavailableView(identifierPrefix: "prepared.split") }
                if hasSaveFailure && !store.isPreparedComponentUnavailable {
                    Section("本次尚未保存") {
                        Button("重新读取备餐，保留分出份数") {
                            if case .failure(let error) = store.reloadPreparedComponents() { saveError = error }
                        }
                        .frame(minHeight: AppTheme.minimumHitTarget)
                        .accessibilityIdentifier("prepared.split.reload")
                    }
                }
                Section {
                    if expected.portionsRemaining > 1 {
                        PreparedPortionCountControl(title: "分出份数", value: $taking,
                            range: 1...(expected.portionsRemaining - 1), identifier: "prepared.split.portions")
                    }
                    if let grouping = expected.grouping {
                        Text("每份\(PreparedMassInput.grams(grouping.massPerPortionDecigrams))")
                        if isValid {
                            Text("原组保留\(expected.portionsRemaining - taking)份；新组\(taking)份")
                                .accessibilityIdentifier("prepared.split.preview")
                        } else { Text("请重新选择可分出的整份数。") }
                    }
                } header: { Text("\(expected.name) · 剩\(expected.portionsRemaining)份") }
                footer: { Text("只分开现有整份，重量、状态和存放保持不变。") }
                if let current, current != expected {
                    Section("记录有更新") {
                        Text("当前：\(current.name)，剩\(current.portionsRemaining)份")
                        Button("按当前记录重新核对") { expected = current }
                            .frame(minHeight: AppTheme.minimumHitTarget)
                            .accessibilityIdentifier("prepared.split.recheck")
                    }
                } else if current == nil { Text("这组已不存在，不能继续分出份数。") }
            }
            .navigationTitle("分出整份").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        switch store.splitPreparedComponent(id: expected.id, taking: taking, newGroupID: siblingID, expected: expected) {
                        case .success: onSuccess(taking); dismiss()
                        case .failure(let error): hasSaveFailure = true; saveError = error
                        }
                    }
                    .disabled(!isValid || store.isPreparedComponentUnavailable)
                    .accessibilityIdentifier("prepared.split.save")
                }
            }
            .preparedFailureAlert($saveError)
        }
    }
}

/// Explicit 44pt controls: a native Stepper's child targets remain 32pt inside a taller row.
struct PreparedPortionCountControl: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let identifier: String
    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) { Text(title); controls }
            } else {
                HStack { Text(title); Spacer(minLength: 8); controls }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
    private var controls: some View {
        HStack(spacing: 12) {
            Button { if value > range.lowerBound { value -= 1 } } label: {
                Image(systemName: "minus").frame(width: AppTheme.minimumHitTarget, height: AppTheme.minimumHitTarget)
                    .contentShape(Rectangle())
            }
            .disabled(value <= range.lowerBound)
            .accessibilityLabel("减少\(title)")
            .accessibilityIdentifier("\(identifier)-Decrement")
            Text("\(value)份").monospacedDigit().fixedSize().foregroundStyle(.primary)
                .accessibilityLabel("当前\(title)，\(value)份")
                .accessibilityIdentifier("\(identifier).value")
            Button { if value < range.upperBound { value += 1 } } label: {
                Image(systemName: "plus").frame(width: AppTheme.minimumHitTarget, height: AppTheme.minimumHitTarget)
                    .contentShape(Rectangle())
            }
            .disabled(value >= range.upperBound)
            .accessibilityLabel("增加\(title)")
            .accessibilityIdentifier("\(identifier)-Increment")
        }
        .buttonStyle(.plain).foregroundStyle(AppTheme.brand)
    }
}

/// Prepared-only supplement; existing seven-domain row counts and restore confirmation stay unchanged.
struct PreparedBackupGroupingPreview: View {
    let components: [PreparedComponent]
    var body: some View {
        if components.contains(where: { $0.grouping != nil || $0.lifecycle != nil }) {
            Section("备餐分装") {
                switch Result(catching: { try PreparedSourceSection.make(components) }) {
                case .failure:
                    Text("备餐分装暂时无法显示，请重新选择备份。")
                case .success(let sections):
                    ForEach(sections.filter { $0.source != nil }) { section in
                        PreparedSourceHeader(section: section)
                        Text(allocationText(section))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("prepared.restore.allocations")
                        ForEach(section.components) { row in
                            Text("\(section.groupLabel(for: row))：\(PreparedLifecyclePresentation.status(row))")
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("prepared.restore.lifecycle.\(row.id.uuidString)")
                            if row.lifecycle != nil {
                                Text(PreparedLifecyclePresentation.events(row).joined(separator: "\n"))
                                    .font(.footnote).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    if components.contains(where: { $0.grouping == nil }) {
                        Text("按份记录的备餐没有重量数据。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(components.filter { $0.grouping == nil && $0.lifecycle != nil }) { row in
                        Text("\(row.name)，\(row.portionsRemaining)份：\(PreparedLifecyclePresentation.status(row))")
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("prepared.restore.lifecycle.\(row.id.uuidString)")
                        Text(PreparedLifecyclePresentation.events(row).joined(separator: "\n"))
                            .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
    private func allocationText(_ section: PreparedSourceSection) -> String {
        section.components.map { row in
            guard let grouping = row.grouping else { return "这组重量无法读取" }
            return "\(section.groupLabel(for: row))：每份\(PreparedMassInput.grams(grouping.massPerPortionDecigrams)) × \(row.portionsRemaining)份"
        }.joined(separator: "；")
    }

}
