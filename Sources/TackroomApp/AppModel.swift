import Foundation
import Observation
import SwiftUI
import TackroomKit

enum SidebarItem: Hashable {
    case overview
    case global
    case project(UUID)
    case agent(String)
    case activity
    case updates
    case proposals
    case tag(String)
    case mcp
    case docs
}

struct ProjectScan: Sendable {
    var access: ProjectAccess
    var results: [HarnessResult]
}

@MainActor
@Observable
final class AppModel {
    var adapters: [HarnessAdapter] = AdapterConfig.load()
    var projects: [Project] = []
    var globalResults: [HarnessResult] = []
    var projectScans: [UUID: ProjectScan] = [:]
    var isScanning = false
    var hasScanned = false
    var lastScan: Date?
    var errorMessage: String?

    var selection: SidebarItem? = .overview
    var selectedSkill: String?
    /// Several skills picked with ⌘/⇧-click; empty or one means normal single selection.
    var selectedSkills: Set<String> = []
    var isMultiSelecting: Bool { selectedSkills.count > 1 }
    /// Skills waiting for a name in the 「新增標籤」 prompt.
    var newTagFor: [String]?
    /// Tag being renamed / about to be deleted (sidebar right-click).
    var renamingTag: String?
    var deletingTag: String?

    func clearMultiSelection() { withAnimation(Theme.spring) { selectedSkills = [] } }
    var searchText = ""
    /// File shown in Quick Look (space bar on a selected skill, or the preview button).
    var previewURL: URL?

    // Writing (M2)
    var lock = Lockfile()
    var projectLocks: [UUID: Lockfile] = [:]
    var drifted: Set<String> = []
    var activity: [ActivityEntry] = []
    /// A plan waiting for the user to look at and confirm.
    var proposal: Plan?
    /// A plan that was cut off last time.
    var interrupted: Plan?
    var isWriting = false
    /// Install sheet, optionally opened with something dropped on the window.
    var installSource: URL?
    var showingInstall = false

    var operations: Operations { Operations(adapters: adapters) }

    // Updates (M3)
    var updates: [UpdateCandidate] = []
    var updateFailures: [String: String] = [:]
    var isCheckingUpdates = false
    /// A stand-in home (`TACKROOM_HOME`) keeps its own check time, so screen checks don't touch the real one.
    private static let lastCheckKey = ProcessInfo.processInfo.environment["TACKROOM_HOME"] == nil ? "lastUpdateCheck" : "lastUpdateCheck.standin"
    var lastUpdateCheck: Date? = UserDefaults.standard.object(forKey: AppModel.lastCheckKey) as? Date
    private var severities: [String: RiskSeverity] = [:]
    private var updateTimerStarted = false

    func severity(of update: UpdateCandidate) -> RiskSeverity { severities[update.id] ?? .none }

    /// 「1 項高風險 · 3 項要注意」 or 「只改了說明文字，沒有風險」.
    func riskSummary(of update: UpdateCandidate) -> String {
        let (high, medium) = riskCounts[update.id] ?? (0, 0)
        if high == 0 && medium == 0 { return L("沒有發現風險") }
        return [high > 0 ? L("\(high) 項高風險") : nil, medium > 0 ? L("\(medium) 項需留意") : nil].compactMap { $0 }.joined(separator: " · ")
    }
    private var riskCounts: [String: (Int, Int)] = [:]

    /// What the last check found for each managed skill with an upstream.
    var upstreamStatus: [String: UpstreamStatus] = [:]
    /// Set when the last check reached no upstream at all (offline, for example).
    var lastCheckProblem: String?
    static let checkInterval: TimeInterval = 6 * 3600
    @ObservationIgnored private var checkGeneration = 0

    /// Checks every managed skill with an upstream. Runs on launch and then
    /// every six hours. With `fetch: false` nothing is downloaded: the copies
    /// fetched last time are compared again with the installed files (after
    /// a local change, so the list never shows a stale picture).
    func checkUpdates(fetch: Bool = true) {
        guard !isCheckingUpdates else { return }
        guard !lock.skills.isEmpty else { updates = []; upstreamStatus = [:]; return }
        isCheckingUpdates = fetch
        checkGeneration += 1
        let generation = checkGeneration
        Task {
            let (result, sev, counts) = await Task.detached(priority: .utility) {
                let result = UpdateChecker().run(fetch: fetch)
                var sev: [String: RiskSeverity] = [:]
                var counts: [String: (Int, Int)] = [:]
                for u in result.updates {
                    // Only what the author changed is judged, not your own edits.
                    let changes = Differ.compare(old: u.authorChangesFrom, new: u.newPath)
                    sev[u.id] = changes.map(\.severity).max() ?? RiskSeverity.none
                    let risks = changes.flatMap(\.risks)
                    counts[u.id] = (risks.filter { $0.severity == .high }.count, risks.filter { $0.severity == .medium }.count)
                }
                return (result, sev, counts)
            }.value
            // A newer check started meanwhile: its answer wins.
            guard generation == checkGeneration else { if fetch { isCheckingUpdates = false }; return }
            riskCounts = counts
            updates = result.updates
            updateFailures = result.failures
            upstreamStatus = result.status
            severities = sev
            if fetch {
                isCheckingUpdates = false
                let checked = result.status.count
                if checked > 0 && result.failures.count == checked {
                    lastCheckProblem = Set(result.failures.values).count == 1 ? result.failures.values.first : L("所有來源都無法檢查")
                } else {
                    lastCheckProblem = nil
                    lastUpdateCheck = Date()
                    UserDefaults.standard.set(lastUpdateCheck, forKey: Self.lastCheckKey)
                }
            }
        }
    }

    private func startDailyChecks() {
        guard !updateTimerStarted else { return }
        updateTimerStarted = true
        checkUpdates()
        Task {
            while true {
                try? await Task.sleep(for: .seconds(600))
                if let last = lastUpdateCheck, Date().timeIntervalSince(last) < Self.checkInterval { continue }
                checkUpdates()
            }
        }
    }

    /// One line for a managed skill's upstream: where updates come from and
    /// what the last check found.
    func upstreamLine(_ name: String) -> (text: String, tone: Color)? {
        guard let entry = lock.skills[name] else { return nil }
        if entry.linkedPath != nil { return (L("檔案在你自己的資料夾，Tackroom 不會替它檢查更新"), Theme.ink3) }
        guard entry.remoteURL != nil else { return (L("沒有上游來源，不會收到更新"), Theme.ink3) }
        if entry.pinned { return (L("已固定目前版本，不檢查更新"), Theme.ink2) }
        let when = lastUpdateCheck.map { L("（\(When.text($0)) \($0.formatted(date: .omitted, time: .shortened)) 檢查）") } ?? ""
        switch upstreamStatus[name] {
        case .current?: return (L("已是最新") + (entry.hasLocalEdits == true ? L("，保留了你的修改") : "") + when, Theme.ink2)
        case .update?: return (L("上游有新版本"), Theme.brand)
        case .skipped?: return (L("上游的新版本已略過") + when, Theme.ink2)
        case .failed(let why)?: return (L("無法檢查：") + why, Theme.amber)
        case nil: return (isCheckingUpdates ? L("檢查中…") : L("尚未檢查"), Theme.ink3)
        }
    }

    private let projectList = ProjectList()

    init() {
        projects = projectList.load()
        // `-selectSkill <name>` / `-selectAgent <id>` on launch, for checking screens.
        let defaults = UserDefaults.standard
        if let agent = defaults.string(forKey: "selectAgent") { selection = .agent(agent) }
        if defaults.bool(forKey: "selectActivity") { selection = .activity }
        if defaults.bool(forKey: "selectUpdates") { selection = .updates }
        if defaults.bool(forKey: "selectProposals") { selection = .proposals }
        if defaults.bool(forKey: "selectMCP") { selection = .mcp }
        if defaults.bool(forKey: "selectDocs") { selection = .docs }
        if let project = defaults.string(forKey: "selectProject"), let p = projects.first(where: { $0.name == project }) {
            selection = .project(p.id)
        }
        pendingSkill = defaults.string(forKey: "selectSkill")
        // Screen checks in a stand-in home only: `-proposeAdopt <name>` opens that
        // preview after the first scan; `-autoConfirm <seconds>` then confirms it.
        if ProcessInfo.processInfo.environment["TACKROOM_HOME"] != nil {
            demoAdopt = defaults.string(forKey: "proposeAdopt")
            // `-multiSelect a,b` opens with several skills picked.
            if let list = defaults.string(forKey: "multiSelect") { selectedSkills = Set(list.split(separator: ",").map(String.init)) }
            demoConfirmAfter = defaults.double(forKey: "autoConfirm")
            demoInstall = defaults.string(forKey: "showInstall")
        }
    }

    private var demoAdopt: String?
    private var demoConfirmAfter: Double = 0
    private var demoInstall: String?

    /// Applied after the first scan, because selection changes clear it.
    private var pendingSkill: String?

    // MARK: Scanning

    func refresh() async {
        guard !isScanning else { return }
        isScanning = true
        let adapters = AdapterConfig.load()
        let projects = self.projects
        let (global, perProject, lock, drifted, activity, interrupted, projectLocks) = await Task.detached(priority: .userInitiated) {
            let global = Inventory.scan(adapters: adapters)
            var perProject: [UUID: ProjectScan] = [:]
            for project in projects {
                let (access, results) = Inventory.scan(project: project, adapters: adapters)
                perProject[project.id] = ProjectScan(access: access, results: results)
            }
            let store = Store()
            let lock = store.readLock()
            var projectLocks: [UUID: Lockfile] = [:]
            for project in projects { projectLocks[project.id] = store.readProjectLock(project) }
            return (global, perProject, lock, store.driftedNames(lock), Activity.load(store: store),
                    Operations(store: store, adapters: adapters).pendingPlan(), projectLocks)
        }.value
        let lockNow = lock
        storedCopies = await Task.detached(priority: .userInitiated) { () -> [String: SkillCopy] in
            let store = Store()
            var out: [String: SkillCopy] = [:]
            for (name, entry) in lockNow.skills {
                let path = store.location(of: name, entry: entry)
                if let copy = Scanner.readEntry(path, name: (path as NSString).lastPathComponent, acceptFlatMarkdown: false) {
                    out[name] = copy
                }
            }
            return out
        }.value
        self.projectLocks = projectLocks
        let mcpProjects = projects
        let mcpAdapters = adapters
        Task {
            let servers = await Task.detached(priority: .utility) {
                var all = MCPInventory.scan(adapters: mcpAdapters)
                for p in mcpProjects {
                    let (_, found) = p.withAccess { path, access -> (ProjectAccess, [MCPServer]) in
                        guard access == .ok else { return (access, []) }
                        var q = p; q.path = path
                        return (access, MCPInventory.scan(adapters: mcpAdapters, project: q).filter { $0.scope == .project })
                    }
                    all += found
                }
                return all
            }.value
            self.mcpServers = servers
        }
        self.proposals = ProposalQueue().all()
        self.adapters = adapters
        self.lock = lock
        dateCache = [:]
        scriptCache = [:]
        tagBook = TagBook()
        pins = Pins()
        moveLegacyTags()
        // Newly changed outside Tackroom: note it once (source unknown). On the
        // first scan, skip names already noted earlier.
        let alreadyNoted = hasScanned ? self.drifted : Set(ExternalLog().load().map(\.name))
        externalLog = ExternalLog().record(newlyDrifted: drifted.subtracting(alreadyNoted).sorted())
        self.drifted = drifted
        self.activity = activity
        self.interrupted = interrupted
        self.globalResults = global
        self.projectScans = perProject
        refreshUsage()
        refreshDocs()
        self.isScanning = false
        self.hasScanned = true
        self.lastScan = Date()
        // Updates that were just applied, skipped or pinned drop out at once;
        // then everything is compared again with the files as they are now.
        updates.removeAll { u in
            guard let e = lock.skills[u.name] else { return true }
            return e.pinned || e.skipped.contains(u.newHash) || e.upstreamHash == u.newHash
        }
        if updateTimerStarted { checkUpdates(fetch: false) }
        startDailyChecks()
        startWatching()
        if let name = demoAdopt, let group = groups(for: .overview).first(where: { $0.name == name }) {
            demoAdopt = nil
            let ops = operations
            let plan = ops.planAdopt(group)
            proposal = plan
            if demoConfirmAfter > 0 {
                let wait = demoConfirmAfter
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(wait))
                    self.run(plan)
                }
            }
        }
        if let path = demoInstall {
            demoInstall = nil
            installSource = URL(fileURLWithPath: path)
            showingInstall = true
        }
        if let pending = pendingSkill {
            pendingSkill = nil
            // `-selectDelay <seconds>` waits first, so the opening can be recorded.
            let delay = UserDefaults.standard.double(forKey: "selectDelay")
            Task { @MainActor in
                if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                self.selectedSkill = pending
            }
        }
    }

    // MARK: What a page shows

    func groups(for item: SidebarItem, search: Bool = true) -> [SkillGroup] {
        let order = adapters.map(\.id)
        var placements: [Placement]
        switch item {
        case .overview:
            placements = globalResults.flatMap(\.placements)
            for scan in projectScans.values {
                placements += scan.results.flatMap(\.placements).filter { $0.scope == .project }
            }
        case .global:
            placements = globalResults.flatMap(\.placements)
        case .project(let id):
            placements = projectScans[id]?.results.flatMap(\.placements) ?? []
        case .agent(let id):
            placements = globalResults.first { $0.adapter.id == id }?.placements ?? []
        case .activity, .updates, .proposals, .mcp, .docs:
            placements = []
        case .tag(let name):
            // Same places as the overview (global and projects), so the count and the page agree.
            let names = tagBook.skills(tagged: name)
            placements = globalResults.flatMap(\.placements).filter { names.contains($0.copy.name) }
            for scan in projectScans.values {
                placements += scan.results.flatMap(\.placements).filter { $0.scope == .project && names.contains($0.copy.name) }
            }
        }
        var groups = Overview.groups(placements: placements, harnessOrder: order)
        // Managed skills that no agent has on right now still belong in the list.
        let keepsStored: Bool = { switch item { case .overview, .global, .tag: return true; default: return false } }()
        if keepsStored {
            let present = Set(groups.map(\.name))
            let tagged: Set<String>? = { if case .tag(let t) = item { return Set(tagBook.skills(tagged: t)) } else { return nil } }()
            for (name, copy) in storedCopies where !present.contains(name) && (tagged?.contains(name) ?? true) {
                groups.append(SkillGroup(name: name, description: copy.description, placements: [], issues: [], stored: copy))
            }
            groups.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        for i in groups.indices where drifted.contains(groups[i].name) { groups[i].issues.append(.drifted) }
        if search, !searchText.isEmpty {
            groups = groups.filter {
                $0.name.localizedCaseInsensitiveContains(searchText) || $0.description.localizedCaseInsensitiveContains(searchText)
                    || tagBook.tags(of: $0.name).contains { $0.localizedCaseInsensitiveContains(searchText) }
            }
        }
        return groups
    }

    func group(named name: String, in item: SidebarItem) -> SkillGroup? {
        groups(for: item).first { $0.name == name }
    }

    /// The whole picture of one skill for the detail pane: every agent's real
    /// state, whichever page (agent, tag, search) it was opened from.
    func detailGroup(named name: String, in item: SidebarItem) -> SkillGroup? {
        let scope: SidebarItem
        if case .project = item { scope = item } else { scope = .overview }
        return groups(for: scope, search: false).first { $0.name == name }
    }

    func isManaged(_ name: String) -> Bool { lock.skills[name] != nil }

    /// Each managed skill's copy in the store (read on every scan).
    var storedCopies: [String: SkillCopy] = [:]

    // MARK: Writing

    /// Shows a plan for the user to confirm.
    func propose(_ make: @escaping @Sendable (Operations) -> Plan) {
        let ops = operations
        Task {
            let plan = await Task.detached { make(ops) }.value
            proposal = plan
        }
    }

    /// Runs a plan right away (switches flip without a confirm step).
    func run(_ plan: Plan, then done: (@MainActor (Error?) -> Void)? = nil) {
        guard !isWriting else { return }
        isWriting = true
        proposal = nil
        let ops = operations
        Task {
            let result: Result<Void, Error> = await Task.detached {
                do {
                    // Project writes run while the project folder's bookmark is open.
                    var project: Project?
                    switch plan.op {
                    case .projectAdd(_, let p), .projectRemove(_, let p): project = p
                    case .editDoc(_, let p): project = p
                    default: break
                    }
                    if let project {
                        try project.withAccess { _, _ in Result { try ops.execute(plan) } }.get()
                    } else {
                        try ops.execute(plan)
                    }
                    return .success(())
                } catch { return .failure(error) }
            }.value
            isWriting = false
            if case .failure(let error) = result {
                errorMessage = error.localizedDescription; done?(error)
            } else {
                showToast(plan.title)
                done?(nil)
            }
            await refresh()
        }
    }

    // MARK: Watching for outside changes (M4)

    var externalLog: [ExternalLog.Entry] = []
    private var watcher: FolderWatcher?
    private var watchedPaths: [String] = []
    private var changeTask: Task<Void, Never>?

    /// Rescans soon after any change in an agent folder or the store.
    private func startWatching() {
        let paths = (adapters.flatMap { a in a.roots.filter { $0.scope == .global }.flatMap { Paths.glob(Paths.expand($0.path)) } }
                     + [Store().root.path, ProposalQueue().dir.path]).sorted()
        guard paths != watchedPaths else { return }
        watchedPaths = paths
        if watcher == nil {
            watcher = FolderWatcher { [weak self] in
                Task { @MainActor in self?.folderChanged() }
            }
        }
        watcher?.watch(paths)
    }

    private func folderChanged() {
        changeTask?.cancel()
        changeTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, !isWriting, !isScanning else { return }
            await refresh()
        }
    }

    // MARK: Round-9 view helpers

    var sidebarShown = true

    // MARK: Column widths (dragged by the user, remembered)

    static let sidebarRange: ClosedRange<CGFloat> = 180...300
    static let listRange: ClosedRange<CGFloat> = 300...560
    static let detailMin: CGFloat = 380
    var sidebarWidth: CGFloat = AppModel.storedWidth("sidebarWidth", 216, AppModel.sidebarRange) {
        didSet { UserDefaults.standard.set(Double(sidebarWidth), forKey: "sidebarWidth") }
    }
    var listWidth: CGFloat = AppModel.storedWidth("listWidth", 392, AppModel.listRange) {
        didSet { UserDefaults.standard.set(Double(listWidth), forKey: "listWidth") }
    }
    /// The window's width, so the list never squeezes the detail pane below `detailMin`.
    var windowWidth: CGFloat = 1180

    /// The list column as drawn: the chosen width, narrowed when the window is small.
    var listColumnWidth: CGFloat {
        let sidebar = sidebarShown ? sidebarWidth + 8 : 0
        let room = windowWidth - sidebar - Self.detailMin
        return max(Self.listRange.lowerBound, min(listWidth, room))
    }

    private static func storedWidth(_ key: String, _ fallback: CGFloat, _ range: ClosedRange<CGFloat>) -> CGFloat {
        guard let v = UserDefaults.standard.object(forKey: key) as? Double else { return fallback }
        return min(max(CGFloat(v), range.lowerBound), range.upperBound)
    }

    // MARK: Menu bar icon (off unless turned on in Settings)

    @ObservationIgnored private var statusController: StatusController?

    var menuBarOn: Bool {
        get { access(keyPath: \.menuBarOn); return UserDefaults.standard.bool(forKey: "menuBarIcon") || Self.menuBarTestFlags }
        set { withMutation(keyPath: \.menuBarOn) { UserDefaults.standard.set(newValue, forKey: "menuBarIcon") }; applyMenuBarSetting() }
    }

    private static var menuBarTestFlags: Bool {
        ProcessInfo.processInfo.environment["TACKROOM_HOME"] != nil
            && (UserDefaults.standard.bool(forKey: "showMenuPanel") || UserDefaults.standard.string(forKey: "testReopen") != nil)
    }

    func applyMenuBarSetting() {
        if menuBarOn, statusController == nil { statusController = StatusController(model: self) }
        if !menuBarOn, let s = statusController { s.remove(); statusController = nil }
    }

    /// Set by the main window so the menu bar can bring it back after it was closed.
    @ObservationIgnored var openMain: (() -> Void)?

    /// Brings the main window forward, opening a new one if the last was closed.
    func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            openMain?()
        }
    }

    /// MCP servers each agent is set up with (read only; M6).
    var mcpServers: [MCPServer] = []
    var mcpGroups: [MCPGroup] { MCPInventory.groups(mcpServers) }
    /// Short message after a change, e.g. 「已套用 web-search」.
    var toast: String?

    func showToast(_ text: String) {
        withAnimation(Theme.spring) { toast = text }
        let current = text
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            if toast == current { withAnimation(Theme.exit) { toast = nil } }
        }
    }

    /// Counts come from the same lists the pages show.
    var skillCount: Int { groups(for: .overview, search: false).filter { !$0.isHarnessOwned }.count }

    // MARK: Tags (any skill, many per skill; ~/.tackroom/tags.json)

    var tagBook = TagBook()

    /// Every tag in the user's list, with how many skills carry it.
    var tagCounts: [(name: String, count: Int)] {
        tagBook.tags.map { ($0.name, groups(for: .tag($0.name), search: false).count) }
    }

    func tags(of name: String) -> [String] { tagBook.tags(of: name) }
    func tag(of name: String) -> String? { tagBook.tags(of: name).first }

    func style(ofTag tag: String?) -> TagStyle {
        TagStyle.of(tag, colorKey: tag.flatMap { tagBook.tag(named: $0)?.color })
    }

    /// The style a skill shows: its first tag's.
    func tagStyle(for skill: String) -> TagStyle { style(ofTag: tag(of: skill)) }

    /// Selected skills that 「交由 Tackroom 管理」 applies to.
    func adoptableGroups(_ names: [String], in item: SidebarItem) -> [SkillGroup] {
        names.compactMap { detailGroup(named: $0, in: item) }.filter { adoptBlock($0) == nil }
    }

    /// Why 「納入管理」 can't apply to this skill, using the same rule the
    /// operation does (a copy in a global folder Tackroom may write to);
    /// nil when it can.
    func adoptBlock(_ group: SkillGroup) -> String? {
        if isManaged(group.name) { return L("已由 Tackroom 管理") }
        if group.isHarnessOwned { return L("隨 agent 附帶") }
        if !SkillName.isSafe(group.name) { return SkillName.problem }
        let usable = group.placements.contains { p in
            guard p.scope == .global, !p.isHarnessOwned, !p.copy.isBrokenLink,
                  let dir = adapter(p.harnessID)?.writeDir.map(Paths.expand) else { return false }
            return (Paths.realpath(p.rootPath) ?? p.rootPath) == (Paths.realpath(dir) ?? dir)
        }
        if usable { return nil }
        if group.placements.contains(where: { $0.scope == .project }) {
            return L("這份 skill 放在專案資料夾裡，跟著專案一起保管與分享；Tackroom 目前只把全域的 skill 納入管理。")
        }
        let names = Set(group.placements.compactMap { adapter($0.harnessID)?.name }).sorted().joined(separator: L("、"))
        return L("它只在 \(names) 的資料夾裡，這些 agent 目前唯讀，Tackroom 不改動。")
    }

    func makePrimaryTag(_ tag: String, for name: String) { tagEdit { try $0.makePrimary(tag, for: name) } }

    func setTag(_ tag: String, on: Bool, for names: [String]) {
        tagEdit { try $0.set(tag, on: on, for: names) }
    }

    /// Creates the tag if new; returns its name.
    @discardableResult
    func createTag(_ raw: String, color: String? = nil) -> String? {
        var name: String?
        tagEdit { name = try $0.create(raw, color: color) }
        return name
    }

    func renameTag(_ old: String, to new: String) {
        tagEdit { try $0.rename(old, to: new) }
        if selection == .tag(old), tagBook.tag(named: new.trimmingCharacters(in: .whitespacesAndNewlines)) != nil {
            selection = .tag(new.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    func recolorTag(_ name: String, to color: String) { tagEdit { try $0.recolor(name, to: color) } }

    func deleteTag(_ name: String) {
        if selection == .tag(name) { selection = .overview }
        tagEdit { try $0.delete(name) }
    }

    private func tagEdit(_ change: (inout TagBook) throws -> Void) {
        var book = tagBook
        do {
            try change(&book)
            withAnimation(Theme.spring) { tagBook = book }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Tags older versions kept in the lockfile move to tags.json once.
    private func moveLegacyTags() {
        guard !tagBook.migrated else { return }
        var legacy: [String: [String]] = [:]
        for (name, entry) in lock.skills where !entry.tags.isEmpty { legacy[name] = entry.tags }
        var book = tagBook
        if (try? book.adoptLegacy(legacy)) != nil { tagBook = book }
    }

    /// When the skill's instructions last changed (the copy agents load).
    func updatedDate(of group: SkillGroup) -> Date? {
        let copy = group.placements.first(where: { $0.state.isActive })?.copy ?? group.distinctCopies.first
        guard let file = copy?.skillFile else { return nil }
        if let hit = dateCache[file] { return hit }
        let date = (try? FileManager.default.attributesOfItem(atPath: file))?[.modificationDate] as? Date
        dateCache[file] = date
        return date
    }

    /// Disk lookups the list and detail repeat on every redraw; cleared on each scan.
    @ObservationIgnored private var dateCache: [String: Date?] = [:]
    @ObservationIgnored private var scriptCache: [String: Int] = [:]

    /// Programs inside a skill folder (leftovers like __pycache__ not counted).
    func scriptCount(_ path: String) -> Int {
        if let hit = scriptCache[path] { return hit }
        var n = 0
        if let walker = FileManager.default.enumerator(atPath: path) {
            for case let rel as String in walker {
                if Scanner.isIgnored((rel as NSString).lastPathComponent) { walker.skipDescendants(); continue }
                if Scanner.scriptExtensions.contains((rel as NSString).pathExtension.lowercased()) { n += 1 }
            }
        }
        scriptCache[path] = n
        return n
    }

    func isManualOnly(_ group: SkillGroup, agent: String?) -> Bool {
        let active = group.placements.filter { $0.state.isActive && (agent == nil || $0.harnessID == agent) }
        return !active.isEmpty && active.allSatisfy { !$0.modelCanUse }
    }

    func needsAttention(_ group: SkillGroup) -> Bool {
        !openIssues(group).isEmpty || updates.contains { $0.name == group.name }
    }

    // MARK: 文件（CLAUDE.md、AGENTS.md…）

    /// An instruction file opened from an agent or project page (instead of a skill).
    var selectedDoc: String?

    /// Instruction files shown on an agent page (the ones it reads by itself)
    /// or a project page (the ones in that project).
    func docs(for item: SidebarItem) -> [AgentDoc] {
        switch item {
        case .agent(let id):
            let all = globalDocs + projects.flatMap { projectDocs[$0.id] ?? [] }
            return all.filter { AgentDocs.readers($0.path).contains(id) }
        case .project(let pid):
            return projectDocs[pid] ?? []
        default:
            return []
        }
    }

    var globalDocs: [AgentDoc] = []
    var projectDocs: [UUID: [AgentDoc]] = [:]
    /// Unsaved edits, kept while the user looks at other documents.
    var docDrafts: [String: String] = [:]

    func refreshDocs() {
        let list = projects
        Task {
            let (global, perProject) = await Task.detached(priority: .utility) { () -> ([AgentDoc], [UUID: [AgentDoc]]) in
                var out: [UUID: [AgentDoc]] = [:]
                for p in list {
                    out[p.id] = p.withAccess { path, access in access == .ok ? AgentDocs.inProject(path, id: p.id) : [] }
                }
                return (AgentDocs.global(), out)
            }.value
            self.globalDocs = global
            self.projectDocs = perProject
        }
    }

    /// Reads a document (inside the project's folder access when needed).
    func readDoc(_ doc: AgentDoc) -> String? {
        if let id = doc.projectID, let p = project(id) {
            return p.withAccess { _, _ in try? String(contentsOfFile: doc.path, encoding: .utf8) }
        }
        return try? String(contentsOfFile: doc.path, encoding: .utf8)
    }

    func saveDoc(_ doc: AgentDoc, text: String, done: @escaping @MainActor (Error?) -> Void) {
        let ops = operations
        let p = doc.projectID.flatMap(project)
        Task {
            let plan = await Task.detached { ops.planEditDoc(path: doc.path, newContents: text, project: p) }.value
            run(plan) { error in
                if error == nil { self.docDrafts[doc.path] = nil }
                done(error)
            }
        }
    }

    // MARK: 常用與釘選

    /// Conversations in the last 30 days that used each skill (Claude Code, Codex).
    var usage: [String: Int] = [:]
    var pins = Pins()

    var usageCounting: Bool {
        get { access(keyPath: \.usageCounting); return UserDefaults.standard.object(forKey: "usageCounting") as? Bool ?? true }
        set {
            withMutation(keyPath: \.usageCounting) { UserDefaults.standard.set(newValue, forKey: "usageCounting") }
            if newValue { refreshUsage() } else { usage = [:] }
        }
    }

    func refreshUsage() {
        guard usageCounting else { usage = [:]; return }
        let names = Set(globalResults.flatMap(\.placements).map(\.copy.name))
        Task {
            let counts = await Task.detached(priority: .utility) { UsageCounter.count(names: names) }.value
            self.usage = counts
        }
    }

    func isPinned(_ name: String) -> Bool { pins.contains(name) }

    func setPinned(_ name: String, _ on: Bool) {
        do { try pins.set(name, pinned: on) } catch { errorMessage = error.localizedDescription }
    }

    // MARK: 「不用處理」

    var dismissed = DismissedNotices()

    /// Issues not marked 「不用處理」.
    func openIssues(_ group: SkillGroup) -> [SkillIssue] { dismissed.open(group) }

    func setDismissed(_ group: SkillGroup, _ issue: SkillIssue, _ on: Bool) {
        do { try dismissed.set(group, issue, dismissed: on) } catch { errorMessage = error.localizedDescription }
    }

    func restoreAllDismissed() {
        do { try dismissed.removeAll() } catch { errorMessage = error.localizedDescription }
    }

    /// How urgent a skill's notices are, for ordering the 需注意 list.
    func urgency(_ group: SkillGroup) -> Int {
        if let u = updates.first(where: { $0.name == group.name }) { return severity(of: u) == .high ? 0 : 2 }
        let issues = openIssues(group)
        if issues.contains(where: { if case .brokenLink = $0 { return true } else { return false } }) { return 1 }
        return issues.isEmpty ? 9 : 3
    }

    /// The one status word a row shows, most important first.
    func status(of group: SkillGroup, agent: String?) -> (text: String, color: Color)? {
        if let u = updates.first(where: { $0.name == group.name }) {
            return severity(of: u) == .high ? (L("新版有高風險"), Theme.red) : (L("有新版本"), Theme.brand)
        }
        for issue in openIssues(group) {
            switch issue {
            case .brokenLink: return (L("捷徑失效"), Theme.red)
            case .drifted: return (L("外部修改"), Theme.amber)
            case .versionsDiffer: return (L("副本不同"), Theme.amber)
            case .duplicate: return (L("重複載入"), Theme.amber)
            case .problem: return (L("檔案有問題"), Theme.amber)
            }
        }
        if group.isOffEverywhere { return (L("全部停用"), Theme.ink3) }
        if isManualOnly(group, agent: agent) { return (L("手動呼叫"), Theme.ink3) }
        return nil
    }

    /// The skill shown when nothing is picked yet: the first one in the list.
    func firstVisibleSkill(in item: SidebarItem) -> String? {
        visibleGroups(in: item).first { !$0.isHarnessOwned }?.name
    }

    /// The list column's filter, kept here so the detail pane follows it.
    var listFilter: ListFilter = .all
    /// Managed by Tackroom or not, on top of `listFilter`.
    var manageFilter: ManageFilter = .all

    func manageFilter(for item: SidebarItem) -> ManageFilter {
        if case .project = item { return .all }
        return manageFilter
    }

    func passes(_ group: SkillGroup, _ filter: ManageFilter) -> Bool {
        switch filter {
        case .all: return true
        case .managed: return isManaged(group.name)
        case .unmanaged: return !isManaged(group.name) && !group.isHarnessOwned
        }
    }

    /// What the list column shows right now (search and filter applied).
    func visibleGroups(in item: SidebarItem) -> [SkillGroup] {
        let management = manageFilter(for: item)
        let all = groups(for: item).filter { passes($0, management) }
        let agent: String? = { if case .agent(let id) = item { return id } else { return nil } }()
        switch listFilter {
        case .all:
            // Pinned first (in pin order), then most used, then by name.
            return all.sorted { a, b in
                let pa = pins.names.firstIndex(of: a.name) ?? Int.max, pb = pins.names.firstIndex(of: b.name) ?? Int.max
                if pa != pb { return pa < pb }
                let ua = usage[a.name] ?? 0, ub = usage[b.name] ?? 0
                if ua != ub { return ua > ub }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        case .attention:
            return all.filter { !$0.isHarnessOwned && needsAttention($0) }
                .sorted { (urgency($0), $0.name.lowercased()) < (urgency($1), $1.name.lowercased()) }
        case .manual: return all.filter { !$0.isHarnessOwned && isManualOnly($0, agent: agent) }
        }
    }

    /// The skill the detail pane shows: the selected one if it is still in the
    /// list, otherwise the first one listed; nil when the list is empty.
    func shownSkill(in item: SidebarItem) -> String? {
        if let s = selectedSkill, visibleGroups(in: item).contains(where: { $0.name == s }) { return s }
        return firstVisibleSkill(in: item)
    }

    /// Things waiting for the user: updates, outside changes not set aside, agent proposals.
    var attentionCount: Int {
        let groups = groups(for: .overview, search: false)
        let driftOpen = drifted.filter { name in groups.first { $0.name == name }.map { openIssues($0).contains(.drifted) } ?? true }
        return updates.count + driftOpen.count + pendingProposals.count
    }

    /// Skills whose files differ from what Tackroom recorded, minus ones set aside.
    var openDrifted: [String] {
        let groups = groups(for: .overview, search: false)
        return drifted.filter { name in groups.first { $0.name == name }.map { openIssues($0).contains(.drifted) } ?? true }.sorted()
    }

    // MARK: Agent proposals (M4)

    var proposals: [Proposal] = []
    var pendingProposals: [Proposal] { proposals.filter { $0.status == .pending } }

    /// Prepares what approving a proposal would do (downloads first for installs).
    func preparePlan(for proposal: Proposal) async -> Plan {
        let ops = operations
        let groups = self.groups(for: .overview)
        let projects = self.projects
        return await Task.detached {
            func registeredProject(at path: String) -> Project? {
                guard let requested = Paths.realpath(path) else { return nil }
                return projects.first { Paths.realpath($0.path) == requested }
            }
            if case .projectRemove(_, let path) = proposal.kind {
                return ops.plan(for: proposal, groups: groups, project: registeredProject(at: path))
            }
            guard case .install(let source, _, _, let projectPath) = proposal.kind else {
                return ops.plan(for: proposal, groups: groups)
            }
            do {
                var folder: URL
                var label = source
                var commit: String?
                if source.hasPrefix("/") {
                    folder = URL(fileURLWithPath: source)
                    if folder.pathExtension.lowercased() == "zip" { folder = try SkillFinder.unzip(folder) }
                    label = "local:" + Paths.abbreviate(source)
                } else {
                    let fetched = try SkillFinder.fetchGitHub(source)
                    folder = fetched.folder
                    label = fetched.source
                    commit = fetched.commit
                }
                let project = projectPath.map { path in
                    registeredProject(at: path) ?? Project(name: (path as NSString).lastPathComponent, path: path)
                }
                return ops.plan(for: proposal, groups: groups, found: SkillFinder.find(in: folder.path),
                                source: label, commit: commit, project: project)
            } catch {
                return Plan(title: proposal.summary, op: .add(name: ""), actor: "cli:" + proposal.agent,
                            preview: [], steps: [], blocker: error.localizedDescription)
            }
        }.value
    }

    func approve(_ proposal: Proposal, plan: Plan) {
        run(plan) { error in
            try? ProposalQueue().decide(proposal.id, error == nil ? .approved : .failed, note: error?.localizedDescription)
            self.proposals = ProposalQueue().all()
        }
    }

    func reject(_ proposal: Proposal) {
        try? ProposalQueue().decide(proposal.id, .rejected, note: L("使用者拒絕"))
        proposals = ProposalQueue().all()
    }

    func toggle(_ name: String, harness: String, on: Bool) {
        let ops = operations
        Task {
            let plan = await Task.detached { ops.planToggle(name, harness: harness, on: on) }.value
            if let blocker = plan.blocker { errorMessage = blocker } else { run(plan) }
        }
    }

    func resumeInterrupted() {
        interrupted = nil
        let ops = operations
        Task {
            let result: Result<Void, Error> = await Task.detached {
                do { try ops.resumePending(); return .success(()) } catch { return .failure(error) }
            }.value
            if case .failure(let error) = result { errorMessage = error.localizedDescription }
            await refresh()
        }
    }

    func discardInterrupted() {
        operations.discardPending()
        interrupted = nil
    }

    /// The instruction file of the copy most agents use, for Quick Look.
    func previewFile(for name: String, in item: SidebarItem) -> URL? {
        guard let group = group(named: name, in: item) else { return nil }
        let copy = group.placements.first(where: { $0.state.isActive })?.copy ?? group.distinctCopies.first
        return copy?.skillFile.map { URL(fileURLWithPath: $0) }
    }

    func adapter(_ id: String) -> HarnessAdapter? { adapters.first { $0.id == id } }

    /// Agent ids in a sentence replaced by their names (「對 codex 關閉」→「對 Codex 關閉」).
    /// Only whole ids, so a skill called codex-helper keeps its name.
    func readable(_ text: String) -> String {
        adapters.reduce(text) { t, a in
            t.replacingOccurrences(of: "(?<![\\w.-])" + NSRegularExpression.escapedPattern(for: a.id) + "(?![\\w-])",
                                   with: NSRegularExpression.escapedTemplate(for: a.name), options: .regularExpression)
        }
    }

    func project(_ id: UUID) -> Project? { projects.first { $0.id == id } }

    /// Agents that exist on this Mac (an app is installed or a folder exists).
    var installedAdapters: [HarnessAdapter] {
        let installed = Set(globalResults.filter(\.isInstalled).map(\.adapter.id))
        return adapters.filter { installed.isEmpty || installed.contains($0.id) }
    }

    func projectSkillCount(_ id: UUID) -> Int? {
        guard let scan = projectScans[id], scan.access == .ok else { return nil }
        return Set(scan.results.flatMap(\.placements).filter { $0.scope == .project }.map(\.copy.name)).count
    }

    var unreadableRoots: [RootReport] {
        globalResults.flatMap(\.roots).filter { $0.error != nil }
    }

    // MARK: Projects

    func addProject(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let path = url.standardizedFileURL.path
        if let existing = projects.first(where: { $0.path == path }) {
            selection = .project(existing.id)
            return
        }
        let project = Project(name: url.lastPathComponent, path: path, bookmark: Project.makeBookmark(for: url))
        projects.append(project)
        projects.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        save()
        selection = .project(project.id)
        Task { await refresh() }
    }

    func relocateProject(_ id: UUID, to url: URL) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        projects[index].path = url.standardizedFileURL.path
        projects[index].name = url.lastPathComponent
        projects[index].bookmark = Project.makeBookmark(for: url)
        save()
        Task { await refresh() }
    }

    func removeProject(_ id: UUID) {
        projects.removeAll { $0.id == id }
        projectScans[id] = nil
        if selection == .project(id) { selection = .overview }
        save()
    }

    private func save() {
        do { try projectList.save(projects) } catch { errorMessage = L("無法儲存專案清單：\(error.localizedDescription)") }
    }
}
