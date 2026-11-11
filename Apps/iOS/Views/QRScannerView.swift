@preconcurrency import AVFoundation
import SwiftUI
import UIKit

/// 페어링 QR 코드 스캔 시트.
struct QRScannerSheet: View {
    /// 읽은 글자를 넘긴다. 페어링 링크가 아니면 안내 문구를 돌려준다.
    var handleScanned: (String) -> String?
    /// 페어링 링크를 읽어 넘긴 뒤 부른다.
    var finished: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var access: CameraAccess = .checking
    @State private var message: String?

    enum CameraAccess { case checking, granted, denied, unavailable }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("QR 코드 스캔")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("닫기") { dismiss() }
                    }
                }
        }
        .task { access = await Self.requestAccess() }
    }

    @ViewBuilder
    private var content: some View {
        switch access {
        case .checking:
            ProgressView()
        case .granted:
            ZStack(alignment: .bottom) {
                QRCameraView { text in
                    if let problem = handleScanned(text) {
                        message = problem
                    } else {
                        finished()
                    }
                }
                .ignoresSafeArea(edges: .bottom)
                .accessibilityLabel("카메라 미리보기")

                Text(message ?? "Mac 앱에 표시된 페어링 QR 코드를 화면에 비추세요.")
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .padding(12)
                    .frame(maxWidth: .infinity)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .padding()
            }
        case .denied:
            ContentUnavailableView {
                Label("카메라 접근이 꺼져 있습니다", systemImage: "camera.fill")
            } description: {
                Text("설정에서 RemoteDebug의 카메라 접근을 허용하거나, 이전 화면에서 주소와 코드를 직접 입력하세요.")
            } actions: {
                Button("설정 열기") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            }
        case .unavailable:
            ContentUnavailableView {
                Label("카메라를 쓸 수 없습니다", systemImage: "camera.fill")
            } description: {
                Text("이 기기에서는 카메라를 쓸 수 없습니다. 이전 화면에서 주소와 코드를 직접 입력하세요.")
            }
        }
    }

    private static func requestAccess() async -> CameraAccess {
        guard AVCaptureDevice.default(for: .video) != nil else { return .unavailable }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .granted
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video) ? .granted : .denied
        default: return .denied
        }
    }
}

/// `AVCaptureMetadataOutput`으로 QR을 읽는 카메라 미리보기.
struct QRCameraView: UIViewRepresentable {
    var onCode: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.videoGravity = .resizeAspectFill
        context.coordinator.attach(to: view)
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        context.coordinator.onCode = onCode
    }

    static func dismantleUIView(_ uiView: PreviewView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    @MainActor
    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        var onCode: (String) -> Void
        private let capture = QRCaptureSession()
        private var lastCode: String?

        init(onCode: @escaping (String) -> Void) {
            self.onCode = onCode
        }

        func attach(to view: PreviewView) {
            view.previewLayer.session = capture.session
            capture.start(delegate: self)
        }

        func stop() {
            capture.stop()
        }

        nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
            let codes = metadataObjects.compactMap { ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }
            guard let code = codes.first else { return }
            MainActor.assumeIsolated {
                // 같은 코드를 연달아 읽으면 한 번만 넘긴다.
                guard code != lastCode else { return }
                lastCode = code
                onCode(code)
            }
        }
    }
}

/// 캡처 세션 구성·시작·정지를 전용 직렬 큐에서 한다.
final class QRCaptureSession: @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.oozoofrog.app.RemoteDebugPhone.qr")
    private var configured = false

    /// 메타데이터 콜백은 메인 큐로 온다.
    func start(delegate: any AVCaptureMetadataOutputObjectsDelegate & Sendable) {
        queue.async { [self] in
            if !configured {
                configured = configure(delegate: delegate)
            }
            if configured, !session.isRunning { session.startRunning() }
        }
    }

    func stop() {
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
    }

    private func configure(delegate: any AVCaptureMetadataOutputObjectsDelegate) -> Bool {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device)
        else { return false }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        guard session.canAddInput(input) else { return false }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return false }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(delegate, queue: .main)
        guard output.availableMetadataObjectTypes.contains(.qr) else { return false }
        output.metadataObjectTypes = [.qr]
        return true
    }
}
