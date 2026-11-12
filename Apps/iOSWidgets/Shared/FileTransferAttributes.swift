import ActivityKit
import Foundation

/// Mac에서 파일을 받는 동안의 라이브 액티비티(잠금 화면, Dynamic Island). 앱과 위젯 확장이 함께 쓴다.
struct FileTransferAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        enum Phase: String, Codable, Hashable {
            case receiving, received, failed, cancelled
        }

        var received: Int64
        var total: Int64
        var phase: Phase
        /// 실패 사유.
        var message: String?
        /// 받기 시작한 시각. 속도와 남은 시간을 계산한다.
        var startedAt: Date

        var fraction: Double { total > 0 ? min(1, Double(received) / Double(total)) : 0 }
    }

    var resourceID: String
    var name: String
    var total: Int64
}
