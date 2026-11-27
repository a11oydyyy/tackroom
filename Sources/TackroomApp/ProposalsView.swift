import SwiftUI
import TackroomKit

/// Agent proposals: list on the left; on the right, the agent's reason and
/// exactly what approving would change.
struct ProposalsView: View {
    @Environment(AppModel.self) private var model
    @State private var selected: String?
    @Namespace private var ns

    var body: some View {
        let pending = model.pendingProposals
        let decided = model.proposals.filter { $0.status != .pending }
        let current = model.proposals.first { $0.id == selected } ?? pending.first ?? decided.first
        HStack(spacing: 0) {
            ListColumn(strong: L("Agent 請求"), rest: pending.isEmpty ? L("目前沒有。") : L("\(pending.count) 個待處理。")) {
                if !pending.isEmpty { GroupHeader(title: L("待處理"), n: pending.count) }
                ForEach(pending) { row($0, current: current) }
                if !decided.isEmpty { GroupHeader(title: L("已處理"), n: decided.count) }
                ForEach(decided.prefix(50)) { row($0, current: current) }
            } footer: {
                HStack(spacing: 2) {
                    Text("Agent 要變更 skill 時會先送出請求，經你同意才執行。")
                        .font(.system(size: 11.5)).foregroundStyle(Theme.ink3)
                    InfoDot(text: L("例如你跟 Codex 說「幫我裝一個整理 PDF 的 skill」，它不會自己動手，而是送一張請求到這裡，你同意了才會改。要讓 agent 會送請求，到設定安裝「給 agent 用的命令列」。"), size: 10.5)
                }
                .padding(EdgeInsets(top: 16, leading: 22, bottom: 22, trailing: 22))
            }
            DetailPane {
                if let current {
                    ProposalReview(proposal: current).id(current.id + current.status.rawValue)
                } else {
                    EmptyDetail(title: L("沒有 agent 的請求"), text: L("Agent 要變更 skill 時會先送出請求，經你同意才執行。"))
                }
            }
        }
    }

    private func row(_ p: Proposal, current: Proposal?) -> some View {
        let adapter = model.adapter(p.agent)
        return TileRow(icon: "M2 9.5 3.8 3h8.4L14 9.5V13H2zM2 9.5h3.5l1 1.5h3l1-1.5H14",
                       color: adapter.map { Color(hex: AgentLogo.color($0)) } ?? Theme.ink2,
                       isSelected: p.id == current?.id, namespace: ns) {
            HStack {
                Text(adapter?.name ?? p.agent).font(.system(size: 13.5, weight: .semibold))
                Spacer()
                Text(When.text(p.createdAt)).font(.system(size: 11)).foregroundStyle(Theme.ink3)
            }
            .frame(height: 19)
            Text(model.readable(p.summary)).font(.system(size: 12)).foregroundStyle(Theme.ink2).lineLimit(1).frame(height: 17)
            Text(statusText(p.status)).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(p.status == .pending ? Theme.brand : p.status == .failed ? Theme.red : Theme.ink3)
                .frame(height: 16).padding(.top, 3)
        }
        .opacity(p.status == .pending ? 1 : 0.7)
        .onTapGesture { withAnimation(Theme.spring) { selected = p.id } }
    }

    private func statusText(_ s: Proposal.Status) -> String {
        switch s {
        case .pending: return L("待處理")
        case .approved: return L("已同意")
        case .rejected: return L("已拒絕")
        case .failed: return L("沒有完成")
        }
    }
}

struct ProposalReview: View {
    @Environment(AppModel.self) private var model
    let proposal: Proposal
    @State private var plan: Plan?
    @State private var appeared = false

    var body: some View {
        let agentName = model.adapter(proposal.agent)?.name ?? proposal.agent
        ZStack(alignment: .bottom) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        if let a = model.adapter(proposal.agent) { AgentLogo(adapter: a, size: 20) }
                        Text(L("\(agentName) 的請求 · ") + proposal.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: 12)).foregroundStyle(Theme.ink2)
                    }
                    Text(model.readable(proposal.summary))
                        .font(.system(size: 30, weight: .bold, design: .serif)).tracking(-0.54)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 10)

                    label(L("理由"))
                    VStack(alignment: .leading, spacing: 6) {
                        Text("“" + proposal.reason + "”").font(.system(size: 13.5)).lineSpacing(4)
                        Text("此說明由 agent 撰寫，請以下方實際變更為準。").font(.system(size: 11)).foregroundStyle(Theme.ink3)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .card()

                    if proposal.status == .pending {
                        label(L("同意後將執行"))
                        if let plan {
                            if let blocker = plan.blocker {
                                Label(blocker, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.amber)
                                    .padding(14).frame(maxWidth: .infinity, alignment: .leading).card()
                            } else {
                                PreviewList(lines: plan.preview)
                            }
                        } else {
                            ProgressView().frame(maxWidth: .infinity).padding()
                        }
                    } else if let note = proposal.note {
                        label(L("結果"))
                        Text(note).font(.system(size: 12.5)).foregroundStyle(Theme.ink2)
                    }
                    Color.clear.frame(height: 90)
                }
                .padding(EdgeInsets(top: 58, leading: 40, bottom: 0, trailing: 40))
                .opacity(appeared ? 1 : 0).offset(y: appeared ? 0 : 6)
            }
            if proposal.status == .pending {
                ActionDock {
                    PillButton(title: L("不同意")) { model.reject(proposal) }
                    PillButton(title: L("同意"), primary: true) {
                        if let plan { model.approve(proposal, plan: plan) }
                    }
                    .disabled(plan == nil || plan?.blocker != nil || model.isWriting)
                }
            }
        }
        .task {
            withAnimation(Theme.ease) { appeared = true }
            guard proposal.status == .pending else { return }
            plan = await model.preparePlan(for: proposal)
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.ink2)
            .padding(.top, 30).padding(.bottom, 10)
    }
}
