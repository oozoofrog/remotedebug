import SwiftUI
import UIKit

/// 이 앱 자신을 업데이트하는 순서. 이 앱의 VPN은 설치하는 동안 꺼지므로 공식 Tailscale로 Mac의 업데이트 페이지를 연다.
struct SelfUpdateGuide: View {
    /// Mac이 알려 준 업데이트 페이지. 없으면 Mac에서 먼저 켜야 한다.
    var pageURL: URL?
    var open: () -> Void
    @State private var copied = false

    var body: some View {
        List {
            if let pageURL {
                Section {
                    step(1, "공식 Tailscale 앱을 열고 연결합니다. 이 앱의 VPN은 자동으로 꺼집니다.")
                    step(2, "이 화면으로 돌아와 ‘업데이트 페이지 열기’를 누르고, Safari에서 ‘설치’를 누릅니다.")
                    step(3, "iOS 창에서 ‘설치’를 누릅니다. 설치하는 동안 이 앱이 닫힙니다.")
                    step(4, "설치가 끝나면 RemoteDebug를 다시 열고 VPN을 켭니다.")
                } header: {
                    Text("순서")
                }
                Section {
                    Button {
                        open()
                    } label: {
                        Label("업데이트 페이지 열기", systemImage: "safari")
                            .frame(maxWidth: .infinity)
                            .font(.headline)
                    }
                    .buttonStyle(.borderedProminent)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
                Section {
                    Button {
                        UIPasteboard.general.url = pageURL
                        copied = true
                    } label: {
                        Label(copied ? "복사함" : "주소 복사", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    Text(pageURL.absoluteString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } footer: {
                    Text("페이지가 열리지 않으면 공식 Tailscale이 연결됐는지 확인하세요. 이 주소는 Mac의 공식 Tailscale tailnet 안에서만 열립니다.")
                }
            } else {
                Section {
                    Text("Mac에서 업데이트 페이지를 아직 열지 않았습니다.")
                        .font(.headline)
                    step(1, "Mac의 RemoteDebug 앱에서 네트워크 > iPhone 앱 업데이트의 ‘공식 Tailscale로 열기’를 누릅니다.")
                    step(2, "이 앱의 빌드 목록을 새로고침하면 업데이트 페이지 주소를 받습니다.")
                } footer: {
                    Text("이 앱은 자기 VPN으로 자기 업데이트를 받을 수 없습니다. iOS가 설치하는 동안 VPN을 끄기 때문입니다.")
                }
            }
        }
        .navigationTitle("RemoteDebug 업데이트")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(PhoneTheme.tint))
                .accessibilityHidden(true)
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(number)단계. \(text)")
    }
}
