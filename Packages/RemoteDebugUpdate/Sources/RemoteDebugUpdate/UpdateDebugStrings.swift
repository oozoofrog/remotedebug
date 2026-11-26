#if DEBUG
import Foundation

/// 개발 빌드에만 컴파일되는 업데이트 UI 문구(영어·한국어·일본어·중국어 간체·번체).
/// 카탈로그 리소스에 두지 않고 `#if DEBUG` 코드 안에 두어 배포판 묶음에 문구가 남지 않게 한다.
enum UpdateDebugStrings {
    static let languages = ["en", "ko", "ja", "zh-Hans", "zh-Hant"]

    enum Key: CaseIterable, Sendable {
        case sectionTitle
        case sectionFooter
        case currentBuild
        case latestBuild
        case checkButton
        case checking
        case upToDate
        case noPublishedBuild
        case updateAvailableTitle
        case updateButton
        case openRemoteDebugButton
        case unreachable
        case notConfigured
        case invalidResponse
        case releaseNotesTitle
        case openFailed
    }

    static let table: [Key: [String]] = [
        .sectionTitle: [
            "Debug Update", "개발 빌드 업데이트", "開発ビルドのアップデート", "开发版本更新", "開發版本更新",
        ],
        .sectionFooter: [
            "Shown only in Debug builds. Updates are installed through the RemoteDebug app.",
            "Debug 빌드에만 표시됩니다. 업데이트는 RemoteDebug 앱을 통해 설치합니다.",
            "Debugビルドでのみ表示されます。アップデートはRemoteDebugアプリからインストールします。",
            "仅在 Debug 版本中显示。更新会通过 RemoteDebug App 安装。",
            "僅在 Debug 版本中顯示。更新會透過 RemoteDebug App 安裝。",
        ],
        .currentBuild: [
            "Current Build", "현재 빌드", "現在のビルド", "当前版本", "目前版本",
        ],
        .latestBuild: [
            "Latest Published", "최신 게시 빌드", "最新の公開ビルド", "最新发布版本", "最新發佈版本",
        ],
        .checkButton: [
            "Check for Updates", "업데이트 확인", "アップデートを確認", "检查更新", "檢查更新",
        ],
        .checking: [
            "Checking for updates…", "업데이트 확인 중…", "アップデートを確認中…", "正在检查更新…", "正在檢查更新…",
        ],
        .upToDate: [
            "This build is up to date.", "최신 빌드입니다.", "最新のビルドです。", "已是最新版本。", "已是最新版本。",
        ],
        .noPublishedBuild: [
            "No published build found on the Mac.", "Mac에 게시된 빌드가 없습니다.", "Macに公開されたビルドがありません。", "Mac 上没有已发布的版本。", "Mac 上沒有已發佈的版本。",
        ],
        .updateAvailableTitle: [
            "Update Available", "새 업데이트 있음", "新しいアップデートがあります", "有可用更新", "有可用更新",
        ],
        .updateButton: [
            "Update", "업데이트", "アップデート", "更新", "更新",
        ],
        .openRemoteDebugButton: [
            "Update in RemoteDebug", "RemoteDebug에서 업데이트", "RemoteDebugでアップデート", "在 RemoteDebug 中更新", "在 RemoteDebug 中更新",
        ],
        .unreachable: [
            "Could not reach the Mac. Turn on VPN in RemoteDebug and try again.",
            "Mac에 닿지 않습니다. RemoteDebug 앱의 VPN을 켠 뒤 다시 시도하세요.",
            "Macに接続できません。RemoteDebugアプリのVPNをオンにしてやり直してください。",
            "无法连接到 Mac。请在 RemoteDebug 中打开 VPN 后重试。",
            "無法連線至 Mac。請在 RemoteDebug 中開啟 VPN 後再試一次。",
        ],
        .notConfigured: [
            "Mac host is not configured.", "Mac 주소가 설정되지 않았습니다.", "Macのアドレスが設定されていません。", "尚未配置 Mac 地址。", "尚未設定 Mac 位址。",
        ],
        .invalidResponse: [
            "Could not read update information.", "업데이트 정보를 읽지 못했습니다.", "アップデート情報を読み込めませんでした。", "无法读取更新信息。", "無法讀取更新資訊。",
        ],
        .releaseNotesTitle: [
            "What's New", "업데이트 내역", "変更内容", "更新说明", "更新說明",
        ],
        .openFailed: [
            "Could not open RemoteDebug. Make sure the RemoteDebug app is installed.",
            "RemoteDebug 앱을 열지 못했습니다. RemoteDebug 앱이 설치돼 있는지 확인하세요.",
            "RemoteDebugアプリを開けませんでした。インストールされているか確認してください。",
            "无法打开 RemoteDebug。请确认已安装 RemoteDebug App。",
            "無法開啟 RemoteDebug。請確認已安裝 RemoteDebug App。",
        ],
    ]

    static var language: String {
        pickLanguage(preferred: Locale.preferredLanguages)
    }

    static func pickLanguage(preferred: [String]) -> String {
        for raw in preferred {
            let lower = raw.lowercased()
            if lower.hasPrefix("ko") { return "ko" }
            if lower.hasPrefix("en") { return "en" }
            if lower.hasPrefix("ja") { return "ja" }
            if lower.hasPrefix("zh") {
                if lower.contains("hant") || lower.contains("-tw") || lower.contains("-hk") || lower.contains("-mo") {
                    return "zh-Hant"
                }
                return "zh-Hans"
            }
        }
        return "en"
    }

    static func text(_ key: Key, language: String = UpdateDebugStrings.language) -> String {
        let values = table[key] ?? []
        let index = languages.firstIndex(of: language) ?? 0
        return values.indices.contains(index) ? values[index] : (values.first ?? "")
    }
}
#endif
