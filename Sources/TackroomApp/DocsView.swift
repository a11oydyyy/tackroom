import SwiftUI
import AppKit
import TackroomKit

/// Agent instruction and reference files (CLAUDE.md, AGENTS.md, DESIGN.md …),
/// global and per project, readable and editable in place.
struct DocsView: View {
    @Environment(AppModel.self) private var model
    @State private var selected: String?
    @Namespace private var ns

    var body: some View {
        let sections: [(title: String, docs: [AgentDoc])] =
            [(L("全域"), model.globalDocs)] + model.projects.map { ($0.name, model.projectDocs[$0.id] ?? []) }
        let all = sections.flatMap(\.docs)
        let current = all.first { $0.path == selected } ?? all.first

        HStack(spacing: 0) {
            ListColumn(strong: L("文件"), rest: all.isEmpty ? L("尚未找到文件。") : L("\(all.count) 份文件。")) {
                ForEach(sections, id: \.title) { section in
                    if !section.docs.isEmpty {
                        GroupHeader(title: section.title, n: section.docs.count)
                        ForEach(section.docs) { doc in
                            TileRow(icon: "M4 1.8h5.5L12.5 5v9.2H4zM9.5 1.8V5h3M6 8h4.5M6 10.5h4.5",
                                    color: doc.readBy != nil ? Theme.brand : Theme.ink2,
                                    isSelected: doc.path == current?.path, namespace: ns) {
                                HStack {
                                    Text(doc.name).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                                    Spacer()
                                    if model.docDrafts[doc.path] != nil {
                                        Text("未儲存").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.amber)
                                    }
                                }
                                .frame(height: 19)
                                Text(Paths.abbreviate((doc.path as NSString).deletingLastPathComponent))
                                    .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.ink2)
                                    .lineLimit(1).truncationMode(.head).frame(height: 17)
                                Text(doc.readBy ?? L("參考文件"))
                                    .font(.system(size: 11)).foregroundStyle(doc.readBy != nil ? Theme.ink2 : Theme.ink3)
                                    .frame(height: 16).padding(.top, 3)
                            }
                            .onTapGesture { withAnimation(Theme.spring) { selected = doc.path } }
                        }
                    }
                }
            } footer: {
                HStack(spacing: 2) {
                    Text("每次儲存都會記錄，並可恢復。")
                        .font(.system(size: 11.5)).foregroundStyle(Theme.ink3)
                    InfoDot(text: L("列出全域的 CLAUDE.md、AGENTS.md、GEMINI.md，以及已登記專案最上層的 .md 檔。"), size: 10.5)
                }
                .padding(EdgeInsets(top: 16, leading: 22, bottom: 22, trailing: 22))
            }

            DetailPane {
                if let current {
                    DocEditor(doc: current).id(current.path)
                } else {
                    EmptyDetail(title: L("沒有文件"), text: L("登記專案後，專案中的 AGENTS.md、DESIGN.md 等文件會顯示於此。"))
                }
            }
        }
        .onAppear { model.refreshDocs() }
    }
}

struct DocEditor: View {
    @Environment(AppModel.self) private var model
    let doc: AgentDoc
    @State private var original: String?
    @State private var text = ""
    @State private var editing = false
    @State private var conflict = false
    @State private var saving = false
    @State private var appeared = false

    private var changed: Bool { original != nil && text != original }

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        Text("文件").font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(0.7)
                            .foregroundStyle(Theme.ink2)
                            .padding(.horizontal, 7).frame(height: 20)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.pillBg))
                        Text(Paths.abbreviate(doc.path)).font(.system(size: 12)).foregroundStyle(Theme.ink2)
                            .lineLimit(1).truncationMode(.head)
                    }
                    Text(doc.name).font(.system(size: 30, weight: .bold, design: .serif)).tracking(-0.54).padding(.top, 10)
                    Text(doc.readBy.map { $0 + L("，每次開始工作時都會遵循。") } ?? L("參考文件，agent 不會自動讀取。"))
                        .font(.system(size: 13.5)).lineSpacing(5).foregroundStyle(Theme.ink2)
                        .fixedSize(horizontal: false, vertical: true).padding(.top, 10)

                    if conflict {
                        HStack(spacing: 10) {
                            Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.amber)
                            Text("編輯期間，此檔案已被其他程式修改。").font(.system(size: 12.5))
                            Spacer()
                            PillButton(title: L("載入最新版本")) { load(force: true) }
                            PillButton(title: L("保留我的版本"), primary: true) { save(force: true) }
                        }
                        .padding(14).card().padding(.top, 18)
                    }

                    Group {
                        if original == nil {
                            Text("無法讀取此檔案。").font(.system(size: 12.5)).foregroundStyle(Theme.ink2)
                        } else if editing {
                            TextEditor(text: $text)
                                .font(.system(size: 13, design: .monospaced))
                                .scrollContentBackground(.hidden)
                                .frame(height: 560)
                                .onChange(of: text) { model.docDrafts[doc.path] = changed ? text : nil }
                        } else if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text("文件為空，按「編輯」開始撰寫。").font(.system(size: 12.5)).foregroundStyle(Theme.ink2)
                        } else {
                            MarkdownLines(lines: text.components(separatedBy: "\n"), offset: 0)
                        }
                    }
                    .padding(EdgeInsets(top: 20, leading: 22, bottom: 22, trailing: 22))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.paper)
                        .shadow(color: .black.opacity(0.07), radius: 10, y: 4)
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(editing ? Theme.brandSoft : Theme.hair, lineWidth: editing ? 1.2 : 0.5)))
                    .padding(.top, 22)

                    Color.clear.frame(height: 100)
                }
                .padding(EdgeInsets(top: 44, leading: 40, bottom: 0, trailing: 40))
                .opacity(appeared ? 1 : 0).offset(y: appeared ? 0 : 6)
            }

            ActionDock {
                if editing {
                    if changed { Text("未儲存").font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.amber).padding(.horizontal, 8) }
                    PillButton(title: changed ? L("放棄修改") : L("完成")) {
                        withAnimation(Theme.ease) {
                            text = original ?? ""; model.docDrafts[doc.path] = nil; editing = false; conflict = false
                        }
                    }
                    PillButton(title: saving ? L("儲存中…") : L("儲存"), primary: true) { save(force: false) }
                        .keyboardShortcut("s")
                        .disabled(!changed || saving)
                } else {
                    PillButton(title: L("在 Finder 顯示")) { NSWorkspace.shared.selectFile(doc.path, inFileViewerRootedAtPath: "") }
                    PillButton(title: L("編輯"), primary: true) { withAnimation(Theme.ease) { editing = true } }
                        .disabled(original == nil)
                }
            }
        }
        .onAppear {
            load(force: false)
            withAnimation(Theme.ease) { appeared = true }
        }
    }

    private func load(force: Bool) {
        original = model.readDoc(doc)
        if !force, let draft = model.docDrafts[doc.path] {
            text = draft; editing = true
        } else {
            text = original ?? ""
            model.docDrafts[doc.path] = nil
        }
        conflict = false
    }

    private func save(force: Bool) {
        // Someone else changed the file while it was open: ask first.
        if !force, let onDisk = model.readDoc(doc), onDisk != original {
            withAnimation(Theme.ease) { conflict = true }
            return
        }
        saving = true
        let saved = text
        model.saveDoc(doc, text: saved) { error in
            saving = false
            if error == nil {
                withAnimation(Theme.ease) { original = saved; editing = false; conflict = false }
            }
        }
    }
}
