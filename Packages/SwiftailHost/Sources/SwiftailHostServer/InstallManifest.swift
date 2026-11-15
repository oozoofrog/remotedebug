// OTA 설치 매니페스트(docs/protocol.md 4.5, 예전 Go 코어의 `Manifest`와 같은 모양).

/// 설치할 앱 하나. 매니페스트의 `metadata`가 된다.
public struct AppPackage: Sendable, Equatable {
    /// 내보낼 IPA 파일. 서버는 이 파일만 연다(요청의 경로는 파일 시스템에 닿지 않는다).
    public var ipaPath: String
    public var bundleIdentifier: String
    public var bundleVersion: String
    public var title: String

    public init(ipaPath: String, bundleIdentifier: String, bundleVersion: String, title: String) {
        (self.ipaPath, self.bundleIdentifier, self.bundleVersion, self.title) = (ipaPath, bundleIdentifier, bundleVersion, title)
    }
}

public enum InstallManifest {
    /// 매니페스트 plist. 값은 XML로 이스케이프한다.
    public static func render(ipaURL: String, app: AppPackage) -> [UInt8] {
        Array("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>items</key>
          <array>
            <dict>
              <key>assets</key>
              <array>
                <dict>
                  <key>kind</key><string>software-package</string>
                  <key>url</key><string>\(escapeXML(ipaURL))</string>
                </dict>
              </array>
              <key>metadata</key>
              <dict>
                <key>bundle-identifier</key><string>\(escapeXML(app.bundleIdentifier))</string>
                <key>bundle-version</key><string>\(escapeXML(app.bundleVersion))</string>
                <key>kind</key><string>software</string>
                <key>title</key><string>\(escapeXML(app.title))</string>
              </dict>
            </dict>
          </array>
        </dict>
        </plist>

        """.utf8)
    }

    /// `itms-services://?action=download-manifest&url=<퍼센트 인코딩한 매니페스트 URL>`(Go `url.QueryEscape`와 같은 자리).
    public static func installURL(manifestURL: String) -> String {
        "itms-services://?action=download-manifest&url=" + percentEncode(manifestURL)
    }

    /// unreserved(RFC 3986 2.3) 밖의 바이트를 모두 `%XX`로 쓴다.
    static func percentEncode(_ text: String) -> String {
        var result = ""
        for byte in text.utf8 {
            switch byte {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "~"):
                result.unicodeScalars.append(Unicode.Scalar(byte))
            default:
                result += "%" + String(byte >> 4, radix: 16, uppercase: true) + String(byte & 0x0F, radix: 16, uppercase: true)
            }
        }
        return result
    }

    /// XML·HTML 본문과 속성 값에 안전하게 쓴다.
    static func escapeXML(_ text: String) -> String {
        var result = ""
        for character in text {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&apos;"
            default: result.append(character)
            }
        }
        return result
    }
}
