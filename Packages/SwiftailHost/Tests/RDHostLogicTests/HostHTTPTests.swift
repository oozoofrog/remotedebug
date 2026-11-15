import Testing
@testable import RDHostLogic

@Suite("전송과의 접점")
struct HostHTTPTests {
    @Test("머리는 소문자 이름으로 첫 값을 찾는다")
    func headerLookup() {
        let request = HostRequest(method: "GET", target: "/v1/info", headers: [("range", "bytes=0-1"), ("range", "bytes=2-3")],
                                  body: nil, contentLength: 0, origin: .direct(remoteIP: "192.0.2.1"))
        #expect(request.header("range") == "bytes=0-1")
        #expect(request.header("host") == nil)
    }
}
