import Foundation
import Testing
@testable import RemoteDebugFeedback

/// 다른 기기(Apple Watch 등)의 로그 묶음: 만들기, 받기, 붙는 글.
struct FeedbackPeerReportTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func line(_ offset: TimeInterval, _ text: String) -> String {
        "\(ISO8601DateFormatter.fractional.string(from: now.addingTimeInterval(offset))) \(text)"
    }

    private func report(source: String = "watch", lines: [String], truncated: Bool = false, at date: Date? = nil) -> FeedbackPeerReport {
        FeedbackPeerReport.make(source: source, lines: lines, truncated: truncated, device: "Watch7,1", system: "watchOS 11.0",
                                appVersion: "3.0.0 (56)", now: date ?? now)!
    }

    @Test func reportCarriesItsCaptureTimeAndTheSpanItCovers() throws {
        let made = report(lines: [line(-120, "측정 시작"), line(-60, "측정 중"), line(-1, "측정 끝")])
        #expect(made.capturedAt == now && !made.isTruncated)
        #expect(made.firstEntryAt == now.addingTimeInterval(-120) && made.lastEntryAt == now.addingTimeInterval(-1))
        let data = try #require(made.encoded())
        #expect(FeedbackPeerReport.decode(data) == made, "다른 기기로 건너가도 같은 값이다")
    }

    @Test func sourceNameIsRestricted() {
        for bad in ["", "Watch", "watch 1", "../x", "시계", String(repeating: "a", count: 25)] {
            #expect(FeedbackPeerReport.make(source: bad, lines: [], truncated: false, device: "", system: "", appVersion: "", now: now) == nil, "\(bad)")
        }
        #expect(FeedbackPeerReport.isValidSource("watch-2"))
    }

    @Test func oversizedLogDropsOldLinesAndSaysSo() throws {
        let long = String(repeating: "가", count: 1500)
        let lines = (0..<400).map { line(TimeInterval($0), "\($0) \(long)") }
        let made = report(lines: lines)
        #expect(made.isTruncated && made.lines.count < 400, "앞쪽 줄을 덜어 내고 그렇게 표시한다")
        #expect(made.lines.last == lines.last, "최근 줄이 남는다")
        #expect(made.firstEntryAt != now, "범위는 남은 줄의 것이다")
        #expect(try #require(made.encoded()).count <= FeedbackPeerReport.maxBytes)
        #expect(report(lines: [line(0, "한 줄")], truncated: true).isTruncated, "기기에서 이미 빠진 것도 전한다")
    }

    @Test func receiverRejectsWhatItCannotBound() throws {
        #expect(FeedbackPeerReport.decode(Data("{}".utf8)) == nil)
        #expect(FeedbackPeerReport.decode(Data(count: FeedbackPeerReport.maxBytes + 1)) == nil)
        var other = report(lines: [])
        other.format = 2
        #expect(FeedbackPeerReport.decode(try #require(other.encoded())) == nil, "모르는 형식은 받지 않는다")
        other.format = 1
        other.source = "../../x"
        #expect(FeedbackPeerReport.decode(try #require(other.encoded())) == nil, "파일 이름이 될 값이라 이름을 다시 본다")
        other.source = "watch"
        other.device = String(repeating: "x", count: 500)
        #expect(FeedbackPeerReport.decode(try #require(other.encoded()))?.device.count == 60)
    }

    @Test func storeKeepsOnePerSourceAndOnlyTheNewestCapture() {
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent("rdpeer-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: storage) }
        let store = FeedbackPeerStore(storage: storage)
        #expect(store.all().isEmpty)
        #expect(store.save(report(lines: [line(-10, "처음")]), receivedAt: now))
        #expect(store.save(report(lines: [line(5, "나중")], at: now.addingTimeInterval(10)), receivedAt: now.addingTimeInterval(11)))
        #expect(!store.save(report(lines: [line(-50, "늦게 도착한 옛 묶음")], at: now.addingTimeInterval(-30)), receivedAt: now.addingTimeInterval(12)),
                "앞서 수집한 묶음이 뒤늦게 와도 새 것을 덮지 않는다")
        #expect(store.all().map(\.report.lines) == [[line(5, "나중")]] && store.all().first?.receivedAt == now.addingTimeInterval(11))
        #expect(store.save(report(source: "pad", lines: []), receivedAt: now) && store.save(report(source: "tv", lines: []), receivedAt: now))
        #expect(!store.save(report(source: "fourth", lines: []), receivedAt: now), "기기 수 한도를 넘으면 두지 않는다")
        #expect(store.all().map(\.report.source) == ["pad", "tv", "watch"])
        FeedbackPeerStore.remove(in: storage)
        #expect(store.all().isEmpty)
    }

    @Test func textSaysWhetherTheCaptureIsLiveOrAnOlderOne() {
        let made = report(lines: [line(-120, "측정 시작"), line(-1, "측정 끝")], truncated: true)
        let live = FeedbackPeerCapture(report: made, receivedAt: now, isLive: true).text(now: now)
        #expect(live.hasPrefix("기기 기록: watch (Watch7,1, watchOS 11.0, 앱 3.0.0 (56))\n"))
        #expect(live.contains("(보내면서 요청해 받음)") && live.contains("2줄 (앞부분이 한도에 걸려 빠짐)"))
        #expect(live.hasSuffix(line(-1, "측정 끝")))
        let stale = FeedbackPeerCapture(report: made, receivedAt: now).text(now: now.addingTimeInterval(1500))
        #expect(stale.contains("요청에 답이 없어 25분 전에 받아 둔 기록을 붙임"), "오래된 묶음은 멀쩡한 것처럼 보이지 않게 한다")
        let json = FeedbackPeerCapture(report: made, receivedAt: now).json
        #expect(json["live"] as? Bool == false && json["truncated"] as? Bool == true && (json["logs"] as? [String])?.count == 2)
        #expect(json["capturedAt"] as? String == ISO8601DateFormatter.fractional.string(from: now) && json["lastEntryAt"] != nil)
        #expect(JSONSerialization.isValidJSONObject(json))
    }

    @Test func waitingGivesUpOnTimeAndHandsLateResultsOn() async {
        let late = Box()
        let fast = await RemoteDebugFeedback.firstResult(of: { 1 }, within: 5) { late.set($0) }
        #expect(fast == 1)
        let slow = await RemoteDebugFeedback.firstResult(of: {
            try? await Task.sleep(nanoseconds: 300_000_000)
            return 2
        }, within: 0.05) { late.set($0) }
        #expect(slow == nil, "제한 시간 안에 끝나지 않으면 기다리지 않는다")
        for _ in 0..<100 where late.value == nil { try? await Task.sleep(nanoseconds: 20_000_000) }
        #expect(late.value == 2, "늦게 온 결과는 버리지 않고 넘긴다")
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Int?
        var value: Int? { lock.withLock { stored } }
        func set(_ value: Int) { lock.withLock { stored = value } }
    }
}

/// 전역 상태를 쓰는 시험은 동의 시험과 같은 묶음에서 차례로 돈다.
extension FeedbackConsentTests {
    @Test func peerReportsFollowConsentAndAreMergedAtSendTime() async throws {
        let fm = FileManager.default
        let storage = fm.temporaryDirectory.appendingPathComponent("rdpeer-\(UUID().uuidString)", isDirectory: true)
        let temporary = fm.temporaryDirectory.appendingPathComponent("rdpeer-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: storage); try? fm.removeItem(at: temporary) }
        let before = RemoteDebugFeedback.withState { ($0.requiresConsent, $0.storage, $0.consent, $0.peerRequest) }
        defer {
            RemoteDebugFeedback.withState {
                $0.requiresConsent = before.0; $0.storage = before.1; $0.consent = before.2; $0.peerRequest = before.3
            }
            FeedbackLog.shared.clear()
        }
        RemoteDebugFeedback.withState {
            $0.requiresConsent = true
            $0.storage = storage
            $0.consent = FeedbackConsent(directory: storage)
            $0.peerRequest = nil
        }
        FeedbackLog.shared.clear()
        let now = Date()
        func data(_ source: String, capturedAt: Date) throws -> Data {
            try #require(FeedbackPeerReport.make(source: source, lines: ["\(ISO8601DateFormatter.fractional.string(from: capturedAt)) 줄"],
                                                 truncated: false, device: "Watch7,1", system: "watchOS 11.0", appVersion: "1.0 (1)",
                                                 now: capturedAt)?.encoded())
        }

        // 동의 전: 만들지도 받지도 붙이지도 않는다.
        #expect(await RemoteDebugFeedback.capturePeerReport(source: "watch") == nil)
        #expect(!RemoteDebugFeedback.storePeerReport(try data("watch", capturedAt: now)))
        #expect(await RemoteDebugFeedback.gatherPeers().isEmpty && !fm.fileExists(atPath: storage.appendingPathComponent("peers").path))

        RemoteDebugFeedback.setRecordingConsent(true, temporaryRoot: temporary)
        RemoteDebugFeedback.log("워치에서 남긴 줄")
        let captured = try #require(await RemoteDebugFeedback.capturePeerReport(source: "watch"))
        #expect(FeedbackPeerReport.decode(captured)?.lines.contains { $0.hasSuffix("워치에서 남긴 줄") } == true)
        #expect(await RemoteDebugFeedback.capturePeerReport(source: "Not Valid") == nil)

        // 요청할 방법이 없으면 받아 둔 것을 "앞서 받은 것"으로 붙인다.
        #expect(RemoteDebugFeedback.storePeerReport(try data("watch", capturedAt: now.addingTimeInterval(-600))))
        var gathered = await RemoteDebugFeedback.gatherPeers()
        #expect(gathered.count == 1 && gathered[0].isLive == false)

        // 요청에 답이 오면 그것으로 바꾸고 "지금 받은 것"으로 붙인다.
        let fresh = try data("watch", capturedAt: now)
        RemoteDebugFeedback.setPeerRequest { [fresh] }
        gathered = await RemoteDebugFeedback.gatherPeers()
        #expect(gathered.count == 1 && gathered[0].isLive && gathered[0].report.capturedAt.timeIntervalSince(now).magnitude < 0.01)

        // 답이 늦으면 받아 둔 것을 붙이고, 늦게 온 답은 다음을 위해 받아 둔다.
        let newer = try data("watch", capturedAt: now.addingTimeInterval(60))
        RemoteDebugFeedback.setPeerRequest {
            try? await Task.sleep(nanoseconds: 300_000_000)
            return [newer]
        }
        gathered = await RemoteDebugFeedback.gatherPeers(timeout: 0.05)
        #expect(gathered.count == 1 && !gathered[0].isLive && gathered[0].report.capturedAt.timeIntervalSince(now).magnitude < 0.01)
        let store = FeedbackPeerStore(storage: storage)
        for _ in 0..<100 where store.all().first?.report.capturedAt.timeIntervalSince(now) ?? 0 < 30 {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(store.all().first?.report.capturedAt.timeIntervalSince(now) ?? 0 > 30, "늦게 온 묶음이 남는다")

        // 동의를 거두면 받아 둔 묶음도 지운다.
        RemoteDebugFeedback.setRecordingConsent(false, temporaryRoot: temporary)
        #expect(store.all().isEmpty && !fm.fileExists(atPath: store.directory.path))
        RemoteDebugFeedback.setPeerRequest { [fresh] }
        #expect(await RemoteDebugFeedback.gatherPeers().isEmpty, "동의가 없으면 요청해 온 것도 받지 않는다")
    }
}
