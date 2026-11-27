import SwiftUI
import TackroomKit

/// Shows exactly what a plan will change; nothing is written until 確認.
struct PlanSheet: View {
    @Environment(AppModel.self) private var model
    let plan: Plan

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            TwoTone(strong: plan.title, rest: plan.blocker == nil ? L("確認前不會進行任何變更。") : "", size: 17)
            if let blocker = plan.blocker {
                Label(blocker, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 13)).foregroundStyle(Theme.amber)
            } else {
                ScrollView(.vertical, showsIndicators: true) { PreviewList(lines: plan.preview).padding(1) }
                    .frame(maxHeight: 320)
                    .fixedSize(horizontal: false, vertical: true)
                if plan.preview.contains(where: { $0.kind == .change || $0.kind == .remove }) {
                    Text("原檔案會移至垃圾桶，並可在「紀錄」中恢復。")
                        .font(.system(size: 11.5)).foregroundStyle(Theme.ink3)
                }
            }
            HStack(spacing: 8) {
                Spacer()
                PillButton(title: L("取消")) { model.proposal = nil }
                    .keyboardShortcut(.cancelAction)
                if plan.blocker == nil {
                    PillButton(title: L("確認"), primary: true) { model.run(plan) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.isWriting)
                }
            }
        }
        .padding(22)
        .frame(width: 520)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.card)
            .shadow(color: .black.opacity(0.18), radius: 24, y: 12)
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.hair, lineWidth: 0.5)))
    }
}

struct PreviewList: View {
    let lines: [PreviewLine]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(lines) { line in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: icon(line.kind))
                        .foregroundStyle(color(line.kind))
                        .frame(width: 14)
                    Text(line.text)
                        .font(.callout)
                        .foregroundStyle(line.kind == .keep ? Theme.ink2 : Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func icon(_ kind: PreviewLine.Kind) -> String {
        switch kind {
        case .add: return "plus"
        case .remove: return "minus"
        case .change: return "arrow.triangle.2.circlepath"
        case .keep: return "equal"
        case .warning: return "exclamationmark.triangle.fill"
        }
    }

    private func color(_ kind: PreviewLine.Kind) -> Color {
        switch kind {
        case .add: return Theme.green
        case .remove: return Theme.red
        case .change: return Theme.brand
        case .keep: return Theme.ink3
        case .warning: return Theme.amber
        }
    }
}
