import Foundation
import TackroomKit

/// Plain-language text for states and issues, kept in one place.
enum Words {
    /// Why a risk finding matters, for someone who doesn't read code.
    static func riskWhy(_ text: String) -> String {
        let table: [(String, String)] = [
            (L("新增會執行的程式"), L("AI 使用此 skill 時可能會執行它。")),
            (L("下載或解碼後直接執行"), L("從網路下載後直接執行，內容無法事先檢視。")),
            (L("要求系統權限"), L("使用管理員權限，或一次刪改大量檔案。")),
            (L("會讀取金鑰"), L("涉及密碼或金鑰，可能被傳送出去。")),
            (L("要 AI 忽略你的指示"), L("要求 AI 忽略你的指示或隱瞞操作，為常見的惡意手法。")),
            (L("新增連到"), L("AI 可能連線到此網址，或將資料傳送過去。")),
            (L("新增會連網的程式"), L("程式會連線到網路。")),
            (L("會讀寫專案以外的檔案"), L("會存取專案以外的位置。")),
            (L("強制 AI 的用語"), L("通常無害，請確認其要求內容。")),
            (L("二進位檔"), L("無法檢視內容，無法確認其用途。")),
        ]
        return table.first { text.contains($0.0) }?.1 ?? ""
    }

    /// How risk checking works, in plain words.
    static let riskMethod = L("Tackroom 用固定規則找特定寫法：會執行的程式、會連網、會讀金鑰、會大量刪檔、叫 AI 瞞著你。只看這次改了什麼，不看作者是誰（帳號也可能被盜）。抓到不代表有惡意，沒抓到也不保證安全。")

    /// Short name of an issue, as in the list row.
    static func issueName(_ issue: SkillIssue) -> String {
        switch issue {
        case .brokenLink: return L("捷徑失效")
        case .drifted: return L("外部修改")
        case .versionsDiffer: return L("副本不同")
        case .duplicate: return L("重複載入")
        case .problem: return L("檔案有問題")
        }
    }

    static func state(_ placement: Placement) -> String {
        switch placement.state {
        case .loaded:
            return placement.modelCanUse ? L("載入") : L("已載入，僅能手動呼叫")
        case .loadedDuplicate:
            return L("載入（另有同名的一份也會載入）")
        case .shadowed:
            return L("被同名的另一份蓋過")
        case .hiddenByStub:
            return L("已用停用替身關閉")
        case .disabledStub:
            return L("停用替身")
        case .disabledInConfig:
            return L("已在 agent 設定中關閉")
        case .notLoadable(let why):
            return L("無法載入：\(why)")
        }
    }

    /// Few words for the inspector's agent rows.
    static func shortState(_ placement: Placement) -> String {
        switch placement.state {
        case .loaded: return placement.modelCanUse ? L("載入") : L("手動")
        case .loadedDuplicate: return L("重複載入")
        case .shadowed: return L("被蓋過")
        case .hiddenByStub, .disabledStub, .disabledInConfig: return L("已停用")
        case .notLoadable: return L("無法載入")
        }
    }

    static func issue(_ issue: SkillIssue, adapters: [HarnessAdapter]) -> String {
        switch issue {
        case .brokenLink(let entry):
            return L("捷徑失效：\(Paths.abbreviate(entry))")
        case .duplicate(let id):
            let name = adapters.first { $0.id == id }?.name ?? id
            return L("\(name) 載入了多份同名 skill")
        case .versionsDiffer:
            return L("各份內容不同")
        case .problem(let text):
            return text
        case .drifted:
            return L("檔案在 Tackroom 外部被修改，來源未知")
        }
    }

    static func shortIssue(_ issue: SkillIssue) -> String {
        switch issue {
        case .brokenLink: return L("捷徑失效")
        case .duplicate: return L("重複")
        case .versionsDiffer: return L("版本不同")
        case .problem: return L("檔案有問題")
        case .drifted: return L("外部修改")
        }
    }

    static func access(_ access: ProjectAccess) -> String? {
        switch access {
        case .ok: return nil
        case .missing: return L("找不到資料夾")
        case .denied(let why): return L("無法讀取：\(why)")
        }
    }

    /// The project a copy lives in, or nil for global copies.
    static func projectName(_ placement: Placement, projects: [Project]) -> String? {
        guard let id = placement.projectID else { return nil }
        return projects.first(where: { $0.id == id })?.name
    }

    static func location(_ placement: Placement, projects: [Project]) -> String {
        if placement.isHarnessOwned { return L("隨 agent 附帶") }
        if let id = placement.projectID, let project = projects.first(where: { $0.id == id }) {
            return L("專案「\(project.name)」")
        }
        return placement.scope == .global ? L("全域") : L("專案")
    }
}
