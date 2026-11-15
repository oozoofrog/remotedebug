import CryptoKit
import Foundation
import Network
import RDHostLogic
import Security
import Synchronization
import Testing

@testable import SwiftailHostServer

@Suite("직접 연결", .serialized, .timeLimit(.minutes(1)))
struct DirectListenerTests {
    /// iPhone(`PhoneClientKit.SPKIPin.hash`)과 같은 계산: P-256 SPKI 머리 + 공개 점의 SHA-256.
    static func phonePin(_ certificate: SecCertificate) -> String? {
        let header: [UInt8] = [0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01,
                               0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00]
        guard let key = SecCertificateCopyKey(certificate), let point = SecKeyCopyExternalRepresentation(key, nil) as Data?,
              point.count == 65 else { return nil }
        return Data(SHA256.hash(data: Data(header) + point)).base64EncodedString()
    }

    @Test func identityIsCreatedOnceAndReloaded() throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try DirectIdentity(directory: directory)
        #expect(DirectIdentity.isValidID(first.id))
        #expect(first.port == 0)
        for name in [DirectIdentity.stateFile, DirectIdentity.certificateFile, DirectIdentity.keyFile] {
            let attributes = try FileManager.default.attributesOfItem(atPath: directory.appending(path: name).path)
            #expect((attributes[.posixPermissions] as? Int) == 0o600, "\(name)")
        }
        let second = try DirectIdentity(directory: directory)
        #expect(second.id == first.id && second.spki == first.spki && second.certificateDER == first.certificateDER)
        let certificate = try #require(SecCertificateCreateWithData(nil, Data(first.certificateDER) as CFData))
        #expect(Self.phonePin(certificate) == first.spki)
        #expect(SecCertificateCopySubjectSummary(certificate) as String? == "RemoteDebug direct")
    }

    /// Go 코어가 쓴 모양(SEC1 `EC PRIVATE KEY`, `{"id","port","hostId"}`)을 그대로 읽는다.
    @Test func goShapedIdentityIsReused() throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = P256.Signing.PrivateKey()
        let certificate = try SelfSignedCertificate.make(key: key, commonName: "RemoteDebug direct", now: Date())
        // RFC 5915 ECPrivateKey(Go `x509.MarshalECPrivateKey`).
        let sec1 = DER.sequence([
            DER.integer([1]),
            DER.octetString(Array(key.rawRepresentation)),
            DER.explicit(0, DER.oid([1, 2, 840, 10045, 3, 1, 7])),
            DER.explicit(1, DER.bitString(Array(key.publicKey.x963Representation), unused: 0)),
        ])
        try PEM.encode(sec1, label: "EC PRIVATE KEY").write(to: directory.appending(path: DirectIdentity.keyFile), atomically: true, encoding: .utf8)
        try PEM.encode(certificate, label: "CERTIFICATE").write(to: directory.appending(path: DirectIdentity.certificateFile), atomically: true, encoding: .utf8)
        try #"{"id":"0123456789abcdef","port":51234,"hostId":"h_1a2b3c4d"}"#
            .write(to: directory.appending(path: DirectIdentity.stateFile), atomically: true, encoding: .utf8)

        let identity = try DirectIdentity(directory: directory)
        #expect(identity.id == "0123456789abcdef" && identity.port == 51_234 && identity.hostID == "h_1a2b3c4d")
        #expect(identity.certificateDER == certificate)
        #expect(identity.spki == Data(SHA256.hash(data: key.publicKey.derRepresentation)).base64EncodedString())
    }

    @Test func mismatchedKeyIsReplaced() throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try DirectIdentity(directory: directory)
        try P256.Signing.PrivateKey().pemRepresentation.write(to: directory.appending(path: DirectIdentity.keyFile), atomically: true, encoding: .utf8)
        let second = try DirectIdentity(directory: directory)
        #expect(second.spki != first.spki && second.id == first.id)
    }

    @Test func lanAddressFilter() {
        for address in ["10.0.0.1", "172.16.5.4", "172.31.255.1", "192.168.1.20", "169.254.3.3", "fe80::1", "fe80::1%en0",
                        "fd00::5", "::ffff:192.168.0.2"] {
            #expect(DirectListener.isLANAddress(address), "\(address)")
        }
        for address in ["100.64.0.1", "100.100.1.2", "fd7a:115c:a1e0::1", "8.8.8.8", "172.32.0.1", "127.0.0.1", "::1",
                        "2001:db8::1", "::ffff:100.64.0.1", "", "nonsense"] {
            #expect(!DirectListener.isLANAddress(address), "\(address)")
        }
    }

    /// 실제 TLS 1.3 핸드셰이크를 루프백에서 하고, 고정 값(SPKI)으로 서버를 확인한 뒤 요청이 `.direct`로 로직에 간다.
    @Test func tlsListenerServesWithPinnedKey() async throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = try DirectIdentity(directory: directory)
        let origins = Mutex<[HostOrigin]>([])
        let listener = try await DirectListener.start(identity: identity, handler: ClosureHandler { request in
            origins.withLock { $0.append(request.origin) }
            return HostResponse(status: 200, body: .bytes(Array("ok".utf8)))
        }, loopbackOnly: true)
        defer { listener.close() }
        #expect(identity.port == Int(listener.port))

        let pinned = Mutex<String?>(nil)
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
            let chain = SecTrustCopyCertificateChain(sec_trust_copy_ref(trust).takeRetainedValue()) as? [SecCertificate]
            let pin = chain?.first.flatMap(Self.phonePin)
            pinned.withLock { $0 = pin }
            complete(pin == identity.spki)
        }, DispatchQueue(label: "pin"))
        let connection = NWConnection(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: listener.port)!,
                                      using: NWParameters(tls: tls))
        defer { connection.cancel() }
        #expect(await ConnectionIO.ready(connection))
        #expect(pinned.withLock { $0 } == identity.spki)
        _ = await ConnectionIO.send(connection, Array("GET /v1/info HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n".utf8))
        var received: [UInt8] = []
        while case .bytes(let more) = await ConnectionIO.receive(connection, maximum: 65_536), !more.isEmpty { received += more }
        let text = String(decoding: received, as: UTF8.self)
        #expect(text.hasPrefix("HTTP/1.1 200") && text.hasSuffix("ok"))
        #expect(origins.withLock { $0 } == [.direct(remoteIP: "127.0.0.1")])
    }

    @Test func savedPortIsReusedAndBusyPortIsReplaced() async throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = try DirectIdentity(directory: directory)
        let handler = ClosureHandler { _ in HostResponse(status: 200) }
        let first = try await DirectListener.start(identity: identity, handler: handler, loopbackOnly: true)
        let port = first.port
        // 저장한 포트를 다른 리스너가 쥐고 있으면 새 포트를 골라 저장한다.
        let second = try await DirectListener.start(identity: identity, handler: handler, loopbackOnly: true)
        #expect(second.port != port && identity.port == Int(second.port))
        first.close()
        second.close()
        try await Task.sleep(for: .milliseconds(200))
        let third = try await DirectListener.start(identity: identity, handler: handler, loopbackOnly: true)
        #expect(third.port == second.port)
        third.close()
        #expect(try DirectIdentity(directory: directory).port == Int(second.port))
    }
}

@Suite("업데이트 페이지", .serialized, .timeLimit(.minutes(1)))
struct UpdatePageTests {
    func page(_ path: String, size: Int64) -> UpdatePageServer.Page {
        UpdatePageServer.Page(bundleID: "com.example.RemoteDebugPhone", title: "Remote <Debug>", version: "0.2.0", buildNumber: "48",
                              minOS: "26.0", size: size, sha256: "ab", publishedAt: "2026-11-16T00:00:00Z", ipaPath: path,
                              icon: [0x89, 0x50])
    }

    @Test func configurationIsValidated() async throws {
        let server = UpdatePageServer()
        await #expect(throws: UpdatePageServer.Failure.invalidPublicURL) {
            try await server.apply(.init(listen: "127.0.0.1:0", publicURL: "http://x/", page: nil))
        }
        await #expect(throws: UpdatePageServer.Failure.invalidPublicURL) {
            try await server.apply(.init(listen: "127.0.0.1:0", publicURL: "https://x/no-slash", page: nil))
        }
        await #expect(throws: UpdatePageServer.Failure.invalidPage) {
            try await server.apply(.init(listen: "127.0.0.1:0", publicURL: "", page: page("", size: 0)))
        }
        await #expect(throws: UpdatePageServer.Failure.notLoopback) {
            try await server.apply(.init(listen: "0.0.0.0:0", publicURL: "", page: nil))
        }
        #expect(try await server.apply(.init(listen: "", publicURL: "", page: nil)) == "")
    }

    @Test func servesPageManifestIPAAndIcon() async throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ipa = directory.appending(path: "RemoteDebug.ipa")
        let bytes = (0..<5_000).map { UInt8(truncatingIfNeeded: $0) }
        try Data(bytes).write(to: ipa)
        let server = UpdatePageServer()
        let publicURL = "https://rd-mac-1a2b3c4d.tail0001.ts.net/secret0123/"
        let address = try await server.apply(.init(listen: "127.0.0.1:0", publicURL: publicURL, page: page(ipa.path, size: 5_000)))
        defer { Task { _ = try? await server.apply(.init(listen: "", publicURL: "", page: nil)) } }
        let port = try #require(UInt16(address.split(separator: ":").last ?? ""))
        #expect(address == "127.0.0.1:\(port)")
        #expect(server.publicURL == publicURL)
        // 같은 주소로 다시 적용하면 리스너를 그대로 둔다.
        #expect(try await server.apply(.init(listen: address, publicURL: publicURL, page: page(ipa.path, size: 5_000))) == address)

        let client = try await RawClient(port: port)
        await client.send("GET /secret0123/ HTTP/1.1\r\nHost: rd-mac-1a2b3c4d.tail0001.ts.net\r\n\r\n")
        let index = try #require(await client.response())
        #expect(index.status == 200 && index.headers["content-security-policy"]?.hasPrefix("default-src 'none'") == true)
        let html = String(decoding: index.body, as: UTF8.self)
        #expect(html.contains("Remote &lt;Debug&gt;") && html.contains("itms-services://?action=download-manifest&amp;url=https%3A%2F%2F"))
        await client.send("GET /manifest.plist HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\n")
        let manifest = try #require(await client.response())
        #expect(String(decoding: manifest.body, as: UTF8.self).contains("\(publicURL)RemoteDebug.ipa"))
        await client.send("GET /x/RemoteDebug.ipa HTTP/1.1\r\nHost: localhost:\(port)\r\nRange: bytes=4990-\r\n\r\n")
        let partial = try #require(await client.response())
        #expect(partial.status == 206 && partial.body == Array(bytes[4_990...]))
        await client.send("GET /icon.png HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\n")
        #expect(try #require(await client.response()).body == [0x89, 0x50])
        await client.send("GET /other HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\n")
        #expect(try #require(await client.response()).status == 404)
        await client.send("POST / HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nContent-Length: 0\r\n\r\n")
        #expect(try #require(await client.response()).status == 405)
    }

    @Test func requestsForOtherHostNamesAreRefused() async throws {
        let server = UpdatePageServer()
        let address = try await server.apply(.init(listen: "127.0.0.1:0", publicURL: "https://rd-mac-1a2b3c4d.tail0001.ts.net/s/",
                                                   page: nil))
        defer { Task { _ = try? await server.apply(.init(listen: "", publicURL: "", page: nil)) } }
        let port = try #require(UInt16(address.split(separator: ":").last ?? ""))
        let client = try await RawClient(port: port)
        for host in ["example.com", "127.0.0.1:1", "rd-mac-1a2b3c4d.tail0001.ts.net:8443", "other.tail0001.ts.net"] {
            await client.send("GET / HTTP/1.1\r\nHost: \(host)\r\n\r\n")
            #expect(try #require(await client.response()).status == 421, "\(host)")
        }
        for host in ["127.0.0.1:\(port)", "LOCALHOST:\(port)", "[::1]:\(port)", "rd-mac-1a2b3c4d.tail0001.ts.net",
                     "rd-mac-1a2b3c4d.tail0001.ts.net:443"] {
            await client.send("GET / HTTP/1.1\r\nHost: \(host)\r\n\r\n")
            #expect(try #require(await client.response()).status == 200, "\(host)")
        }
    }

    @Test func goneAndChangedBuilds() async throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ipa = directory.appending(path: "a.ipa")
        try Data(repeating: 1, count: 10).write(to: ipa)
        let server = UpdatePageServer()
        let address = try await server.apply(.init(listen: "127.0.0.1:0", publicURL: "", page: page(ipa.path, size: 11)))
        defer { Task { _ = try? await server.apply(.init(listen: "", publicURL: "", page: nil)) } }
        // publicURL이 없으면 iPhone에 알릴 주소도 없다.
        #expect(server.publicURL == "")
        let port = try #require(UInt16(address.split(separator: ":").last ?? ""))
        let client = try await RawClient(port: port)
        await client.send("GET /RemoteDebug.ipa HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\n")
        let changed = try #require(await client.response())
        #expect(changed.status == 410 && String(decoding: changed.body, as: UTF8.self) == "build changed\n")
        await client.send("GET /manifest.plist HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\n")
        #expect(try #require(await client.response()).status == 404)
        try FileManager.default.removeItem(at: ipa)
        await client.send("GET /RemoteDebug.ipa HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\n")
        #expect(String(decoding: try #require(await client.response()).body, as: UTF8.self) == "build is gone\n")
    }
}
