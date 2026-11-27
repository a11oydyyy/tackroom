import SwiftUI
import UniformTypeIdentifiers
import TackroomKit

/// Install from a GitHub repo, a folder or a .zip: pick skills and agents, see
/// what will change, then install.
struct InstallSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var address = ""
    @State private var loading = false
    @State private var found: [FoundSkill] = []
    @State private var chosen: Set<String> = []
    @State private var agents: Set<String> = []
    @State private var source = ""
    @State private var commit: String?
    @State private var error: String?
    @State private var picking = false
    @State private var plan: Plan?
    /// nil = global; otherwise a registered project.
    @State private var target: UUID?
    @State private var risks: [String: RiskSeverity] = [:]
    @State private var riskTexts: [String: [String]] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            TwoTone(strong: found.isEmpty ? L("安裝 skill") : L("安裝 \(chosen.count) 個"),
                    rest: found.isEmpty ? L("貼上 GitHub 網址，或拖入資料夾、.zip 檔。") : L("請先檢視內容與風險，按「安裝」後才會安裝。"), size: 20)

            if found.isEmpty {
                HStack(spacing: 8) {
                    HStack(spacing: 7) {
                        Image(systemName: "link").font(.system(size: 12)).foregroundStyle(Theme.ink3)
                        TextField("", text: $address, prompt: Text("GitHub 網址或 owner/repo").foregroundStyle(Theme.ink3))
                            .textFieldStyle(.plain).onSubmit(fetch)
                    }
                    .padding(.horizontal, 10).frame(height: 32)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.soft))
                    PillButton(title: L("取得"), action: fetch).disabled(address.isEmpty || loading)
                }
                dropZone
            }

            if loading { ProgressView().frame(maxWidth: .infinity) }
            if let error { Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 12.5)).foregroundStyle(Theme.amber) }

            if !found.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(found.enumerated()), id: \.element.id) { i, skill in
                        let risk = risks[skill.name] ?? .none
                        Button {
                            if chosen.contains(skill.name) { chosen.remove(skill.name) } else { chosen.insert(skill.name) }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: chosen.contains(skill.name) ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 16)).foregroundStyle(chosen.contains(skill.name) ? Theme.brand : Theme.ink3)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(skill.name).font(.system(size: 13, weight: .semibold))
                                    Text(skill.description).font(.system(size: 11.5)).foregroundStyle(Theme.ink2).lineLimit(1)
                                }
                                Spacer(minLength: 6)
                                Text(risk == .high ? L("有高風險") : risk == .medium ? L("要注意") : L("沒有發現風險"))
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(risk == .high ? Theme.red : risk == .medium ? Theme.amber : Theme.green)
                                    .padding(.horizontal, 8).frame(height: 20)
                                    .background(Capsule().fill((risk == .high ? Theme.red : risk == .medium ? Theme.amber : Theme.green).opacity(0.12)))
                                    .help(riskTexts[skill.name]?.joined(separator: "\n") ?? "")
                            }
                            .padding(.horizontal, 14).frame(height: 50)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .overlay(alignment: .top) { if i > 0 { Theme.line.frame(height: 0.5) } }
                    }
                }
                .card()

                let flagged = found.filter { !(riskTexts[$0.name] ?? []).isEmpty }
                if !flagged.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(flagged, id: \.id) { skill in
                            ForEach(Array(Set(riskTexts[skill.name] ?? [])).sorted().prefix(3), id: \.self) { t in
                                (Text(skill.name + L("：")).fontWeight(.semibold) + Text(t) + Text(Words.riskWhy(t).isEmpty ? "" : L("。") + Words.riskWhy(t)).foregroundStyle(Theme.ink2))
                                    .font(.system(size: 11.5)).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        RiskMethodNote().padding(.top, 2)
                    }
                    .padding(.horizontal, 4)
                }

                HStack(spacing: 10) {
                    Text("裝到").font(.system(size: 12)).foregroundStyle(Theme.ink2)
                    Picker("", selection: $target) {
                        Text("全域").tag(UUID?.none)
                        ForEach(model.projects) { project in
                            Text("專案：\(project.name)").tag(UUID?.some(project.id))
                        }
                    }
                    .labelsHidden().fixedSize()
                    Text("給").font(.system(size: 12)).foregroundStyle(Theme.ink2).padding(.leading, 6)
                    ForEach(choosableAgents) { adapter in
                        Button {
                            if agents.contains(adapter.id) { agents.remove(adapter.id) } else { agents.insert(adapter.id) }
                        } label: {
                            HStack(spacing: 6) {
                                AgentLogo(adapter: adapter, size: 16)
                                Text(adapter.name).font(.system(size: 12, weight: .medium))
                            }
                            .padding(.leading, 4).padding(.trailing, 10).frame(height: 26)
                            .background(Capsule().fill(agents.contains(adapter.id) ? Theme.brand.opacity(0.14) : Theme.soft))
                            .overlay(Capsule().strokeBorder(agents.contains(adapter.id) ? Theme.brand : .clear, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
                if let plan, plan.blocker == nil { PreviewList(lines: plan.preview) }
                if let blocker = plan?.blocker {
                    Label(blocker, systemImage: "exclamationmark.triangle").font(.system(size: 12.5)).foregroundStyle(Theme.amber)
                }
            }

            HStack(spacing: 8) {
                Spacer()
                PillButton(title: L("取消")) { close() }.keyboardShortcut(.cancelAction)
                PillButton(title: chosen.isEmpty ? L("安裝") : L("安裝 \(chosen.count) 個"), primary: true) {
                    if let plan { model.run(plan); close() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(plan == nil || plan?.blocker != nil || chosen.isEmpty || agents.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 620)
        .background(Theme.win)
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder, .zip]) { result in
            if case .success(let url) = result { load(url) }
        }
        .onAppear {
            if case .project(let id) = model.selection { target = id }
            agents = Set(choosableAgents.map(\.id))
            if let url = model.installSource { load(url) }
        }
        .onChange(of: target) {
            agents = Set(choosableAgents.map(\.id))
            replan()
        }
        .onChange(of: chosen) { replan() }
        .onChange(of: agents) { replan() }
    }

    private var dropZone: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Theme.hair, style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.pillBg))
            .frame(height: 86)
            .overlay {
                VStack(spacing: 6) {
                    PathIcon(d: "M8 2v8M5 7l3 3 3-3M2.5 11v2.5h11V11", box: 16, size: 20, lineWidth: 1.4)
                    HStack(spacing: 4) {
                        Text("將資料夾或 .zip 拖到此處，或")
                        Button("選擇…") { picking = true }.buttonStyle(.plain).foregroundStyle(Theme.brand).fontWeight(.semibold)
                    }
                    .font(.system(size: 12))
                }
                .foregroundStyle(Theme.ink2)
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first else { return false }
                load(url)
                return true
            }
    }

    /// Agents Tackroom can install for, at the chosen place.
    private var choosableAgents: [HarnessAdapter] {
        model.adapters.filter { target == nil ? $0.writeDir != nil : $0.projectWriteDir != nil }
    }

    private func binding(_ id: String, in set: Binding<Set<String>>) -> Binding<Bool> {
        Binding(get: { set.wrappedValue.contains(id) },
                set: { on in if on { set.wrappedValue.insert(id) } else { set.wrappedValue.remove(id) } })
    }

    private func fetch() {
        let spec = address
        start {
            let (folder, source, commit) = try SkillFinder.fetchGitHub(spec)
            return (SkillFinder.find(in: folder.path), source, commit)
        }
    }

    private func load(_ url: URL) {
        start {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let folder = url.pathExtension.lowercased() == "zip" ? try SkillFinder.unzip(url) : url
            return (SkillFinder.find(in: folder.path), "local:" + Paths.abbreviate(url.path), nil)
        }
    }

    private func start(_ work: @escaping @Sendable () throws -> ([FoundSkill], String, String?)) {
        loading = true
        error = nil
        found = []
        plan = nil
        Task {
            let result = await Task.detached { Result { try work() } }.value
            loading = false
            switch result {
            case .success(let (skills, source, commit)):
                found = skills
                Task {
                    let checked = await Task.detached {
                        skills.map { skill -> (String, RiskSeverity, [String]) in
                            let risks = Differ.compare(old: "/nonexistent-\(UUID().uuidString)", new: skill.path).flatMap(\.risks)
                            return (skill.name, risks.map(\.severity).max() ?? .none, risks.map(\.text))
                        }
                    }.value
                    for (name, sev, texts) in checked { risks[name] = sev; riskTexts[name] = texts }
                }
                self.source = source
                self.commit = commit
                chosen = Set(skills.map(\.name))
                if skills.isEmpty { error = L("未找到 skill（需包含 SKILL.md 的資料夾）。") }
                replan()
            case .failure(let e):
                error = e.localizedDescription
            }
        }
    }

    private func replan() {
        let picked = found.filter { chosen.contains($0.name) }
        guard !picked.isEmpty else { plan = nil; return }
        let ops = model.operations
        let harnesses = model.adapters.map(\.id).filter { agents.contains($0) }
        let source = self.source, commit = self.commit
        let project = target.flatMap { model.project($0) }
        Task {
            plan = await Task.detached {
                if let project {
                    return project.withAccess { path, _ in
                        var p = project
                        p.path = path
                        return ops.planProjectAdd(picked, project: p, harnesses: harnesses, source: source)
                    }
                }
                return ops.planAdd(picked, harnesses: harnesses, source: source, commit: commit)
            }.value
        }
    }

    private func close() {
        model.installSource = nil
        model.showingInstall = false
        dismiss()
    }
}
