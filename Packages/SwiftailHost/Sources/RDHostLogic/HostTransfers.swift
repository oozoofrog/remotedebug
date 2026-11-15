import Foundation

/// 고정 HTTP 접점의 추가 관찰 접점. 전송은 파일 구간을 보내는 동안 이 프로토콜도 지원하면 호출한다.
/// 같은 응답의 file 경로로 조회한다. 진행률은 온전히 쓴 조각 뒤, 읽기 오류는 onFinished 전에 알린다.
public protocol HostFileTransferMonitoring: HostRequestHandling {
    func transferState(filePath: String) -> HostLogic.TransferState?
    func recordTransferProgress(filePath: String, sentBodyBytes: UInt64)
    func recordTransferReadFailure(filePath: String)
}

extension HostLogic: HostFileTransferMonitoring {
    struct FileTransfer {
        let sessionID: String
        let offset: UInt64
        let count: UInt64
    }

    public func transferState(filePath: String) -> TransferState? {
        locked {
            guard let transfer = fileTransfers[filePath] else { return nil }
            return transferState(sessionID: transfer.sessionID)
        }
    }

    public func recordTransferProgress(filePath: String, sentBodyBytes: UInt64) {
        locked {
            guard let transfer = fileTransfers[filePath], let session = sessions[transfer.sessionID] else { return }
            let count = min(sentBodyBytes, transfer.count)
            session.addSpan(transfer.offset..<(transfer.offset + count))
        }
    }

    public func recordTransferReadFailure(filePath: String) {
        locked {
            guard let transfer = fileTransfers[filePath], let session = sessions[transfer.sessionID] else { return }
            failSession(session)
        }
    }
}
