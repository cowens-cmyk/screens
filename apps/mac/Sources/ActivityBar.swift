import PresenterCore
import SwiftUI

/// Across the top of the slides while files are imported or the plan is
/// loaded into memory, on every page of the main window. It takes room
/// above the page rather than covering it, so no slide tile and none of the
/// live controls are ever under it, and nothing in it waits on the operator.
/// What it says comes from the model's ActivityBoard; this only draws it.
struct ActivityBar: View {
    let model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ActivityLines(lines: model.activity.lines) { model.dismissActivity($0) }
            .animation(HopeMotion.ui(reduced: reduceMotion), value: model.activity.lines.map(\.id))
    }
}

/// The lines themselves, apart from the model, so a test or a preview can
/// draw them from a board of its own.
struct ActivityLines: View {
    let lines: [ActivityBoard.Line]
    var dismiss: (ActivityBoard.Line.Kind) -> Void = { _ in }

    var body: some View {
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(lines) { line in
                    row(line)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private func row(_ line: ActivityBoard.Line) -> some View {
        if line.isSummary {
            HStack(spacing: 8) {
                Image(systemName: line.tone == .problem ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(line.tone == .problem ? HopeStyle.amber : Color.secondary)
                Text(line.title)
                    .font(.caption)
                    .foregroundStyle(line.tone == .problem ? .primary : .secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    dismiss(line.kind)
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Close")
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                if let fraction = line.fraction {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                }
                Text([line.title, line.detail].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " \u{00B7} "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .monospacedDigit()
            }
        }
    }
}
