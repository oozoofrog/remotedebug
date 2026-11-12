import RDModels
import SwiftUI
import UIKit

/// Mac이 보낸 링크 하나: 열기, 공유, 주소를 이루는 부분(스킴·호스트·경로·쿼리).
struct LinkDetailView: View {
    var resource: ResourceDescriptor
    @Environment(\.openURL) private var openURL
    @State private var openFailed = false
    @State private var copied: String?

    private var url: URL? { resource.link.flatMap(URL.init(string:)) }
    private var components: URLComponents? { url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) } }

    static func isWeb(_ link: String?) -> Bool {
        guard let scheme = link.flatMap(URL.init(string:))?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(resource.name)
                        .font(.headline)
                    Text(resource.link ?? "")
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .padding(.vertical, 4)
            }

            Section {
                if let url {
                    Button {
                        openURL(url) { accepted in openFailed = !accepted }
                    } label: {
                        Label(Self.isWeb(resource.link) ? "Safari에서 열기" : "앱에서 열기", systemImage: Self.isWeb(resource.link) ? "safari" : "arrow.up.forward.app")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    ShareLink(item: url) {
                        Label("다른 앱으로 보내기", systemImage: "square.and.arrow.up")
                    }
                }
                Button {
                    UIPasteboard.general.string = resource.link
                    copied = "주소"
                } label: {
                    Label(copied == "주소" ? "복사함" : "주소 복사", systemImage: copied == "주소" ? "checkmark" : "doc.on.doc")
                }
                if openFailed {
                    Label("이 주소를 열 수 있는 앱이 없습니다. 그 스킴을 쓰는 앱이 설치돼 있는지 확인하세요.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            } footer: {
                if !Self.isWeb(resource.link) {
                    Text("앱 딥 링크는 그 스킴을 등록한 앱이 설치돼 있어야 열립니다.")
                }
            }

            if let components {
                Section("주소 구성") {
                    part("스킴", components.scheme)
                    part("호스트", components.host)
                    if let port = components.port { part("포트", String(port)) }
                    part("경로", components.path.isEmpty ? nil : components.path)
                    part("프래그먼트", components.fragment)
                }
                if let items = components.queryItems, !items.isEmpty {
                    Section("쿼리 \(items.count)개") {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            LabeledContent(item.name) {
                                Text(item.value ?? "(값 없음)")
                                    .font(.callout.monospaced())
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
            }

            Section("정보") {
                LabeledContent("Mac에서 보낸 시각", value: resource.publishedAt.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("주소 길이", value: "\((resource.link ?? "").count)자")
                LabeledContent("링크 id") { Text(resource.id).font(.caption.monospaced()).textSelection(.enabled) }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(resource.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func part(_ title: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            LabeledContent(title) {
                Text(value)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
            }
        }
    }
}
