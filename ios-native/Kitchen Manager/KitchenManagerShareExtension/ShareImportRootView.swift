import SwiftUI

struct ShareImportRootView: View {
    @ObservedObject var viewModel: ShareImportViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let onCancel: () -> Void
    let onFinished: () -> Void

    @State private var editableText: String = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    statusView
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("导入到 Kitchen Manager")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", role: .cancel) {
                        onCancel()
                    }
                    .accessibilityIdentifier("shareExtension.cancel.button")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加到 Kitchen Manager") {
                        viewModel.submit()
                    }
                    .disabled(!canSubmit)
                    .accessibilityIdentifier("shareExtension.submit.button")
                }
            }
        }
        .onChange(of: viewModel.state) { _, newState in
            if case .saved = newState {
                let delay = reduceMotion ? 0.15 : 0.6
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    onFinished()
                }
            }
        }
    }

    private var canSubmit: Bool {
        if case .ready = viewModel.state { return true }
        return false
    }

    @ViewBuilder
    private var statusView: some View {
        switch viewModel.state {
        case .loading:
            HStack(spacing: 12) {
                ProgressView()
                Text("正在读取分享内容…")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("正在读取分享内容")

        case .ready(let preview):
            previewSection(preview, footnote: "可以添加到 Kitchen Manager")

        case .unsupported(let message):
            unsupportedSection(message: message)

        case .saving(let preview):
            VStack(alignment: .leading, spacing: 16) {
                previewCard(preview)
                HStack(spacing: 12) {
                    ProgressView()
                    Text("正在保存…")
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("正在保存")
            }

        case .saved:
            VStack(alignment: .leading, spacing: 12) {
                Label("已保存", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.green)
                Text("打开 Kitchen Manager 即可继续导入。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("已保存，打开 Kitchen Manager 即可继续导入")

        case .failed(let preview, let message):
            VStack(alignment: .leading, spacing: 16) {
                previewCard(preview)
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.red)
                    .accessibilityLabel("保存失败：\(message)")
                Button("重试") {
                    viewModel.submit()
                }
                .frame(minHeight: 44)
                .accessibilityIdentifier("shareExtension.retry.button")
            }
        }
    }

    private func previewSection(_ preview: ShareImportViewModel.Preview, footnote: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            previewCard(preview)
            if preview.typeDescription != "网页链接" {
                TextEditor(text: $editableText)
                    .frame(minHeight: 100, maxHeight: 220)
                    .scrollContentBackground(.hidden)
                    .background(Color(uiColor: .secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel("分享文字，可编辑")
                    .onAppear { editableText = preview.detail ?? "" }
                    .onChange(of: editableText) { _, newValue in
                        viewModel.updateText(newValue)
                    }
            }
            Text(footnote)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func previewCard(_ preview: ShareImportViewModel.Preview) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(preview.typeDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text(preview.headline)
                .font(.headline)
                .lineLimit(2)
            if preview.typeDescription == "网页链接", let detail = preview.detail {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(preview.typeDescription)：\(preview.headline)")
    }

    private func unsupportedSection(message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("内容不受支持", systemImage: "xmark.circle.fill")
                .font(.headline)
                .foregroundStyle(.red)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("内容不受支持：\(message)")
    }
}
