@preconcurrency import AVFoundation
import CoreImage
import PhotosUI
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
    @State private var picked: PhotosPickerItem?

    enum CameraAccess { case checking, granted, denied, unavailable }

    var body: some View {
        NavigationStack {
            content
                .safeAreaInset(edge: .bottom) {
                    // 카메라 화면은 안내를 미리보기 위에 겹쳐 보인다. 카메라가 없을 때는 사진을 읽은 결과만 여기에 보인다.
                    if access != .granted, let message {
                        Text(message)
                            .font(.subheadline)
                            .multilineTextAlignment(.center)
                            .padding(12)
                            .frame(maxWidth: .infinity)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                            .padding()
                    }
                }
                .navigationTitle("QR 코드 스캔")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("닫기") { dismiss() }
                    }
                    // 시스템 사진 선택기라 사진 접근 권한 없이 고른 사진만 받는다. 카메라를 못 쓸 때도 쓸 수 있다.
                    ToolbarItem(placement: .primaryAction) {
                        PhotosPicker(selection: $picked, matching: .images) {
                            Label("사진에서 읽기", systemImage: "photo")
                        }
                    }
                }
        }
        .task { access = await Self.requestAccess() }
        .onChange(of: picked) { _, item in
            guard let item else { return }
            picked = nil
            Task { await read(item) }
        }
    }

    /// 고른 사진에서 QR을 읽어 카메라로 읽은 것과 같은 길로 넘긴다.
    private func read(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            message = String(localized: "사진을 불러오지 못했습니다.")
            return
        }
        let codes = await Task.detached { QRImageReader.codes(in: data) }.value
        guard !codes.isEmpty else {
            message = String(localized: "사진에서 QR 코드를 찾지 못했습니다.")
            return
        }
        // 사진에 QR이 여러 개면 페어링 링크인 것을 쓴다.
        var problem: String?
        for code in codes {
            problem = handleScanned(code)
            if problem == nil {
                finished()
                return
            }
        }
        message = problem
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

                Text(message ?? String(localized: "Mac 앱에 표시된 페어링 QR 코드를 화면에 비추세요."))
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
                Text("설정에서 RemoteDebug의 카메라 접근을 허용하거나, Mac이 보낸 페어링 링크를 이 iPhone에서 여세요.")
            } actions: {
                Button("설정 열기") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            }
        case .unavailable:
            ContentUnavailableView {
                Label("카메라를 쓸 수 없습니다", systemImage: "camera.fill")
            } description: {
                Text("이 기기에서는 카메라를 쓸 수 없습니다. Mac이 보낸 페어링 링크를 이 iPhone에서 여세요.")
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

/// 사진 속 QR 코드의 글자를 읽는다.
enum QRImageReader {
    static func codes(in data: Data) -> [String] {
        guard let image = CIImage(data: data, options: [.applyOrientationProperty: true]),
              let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        else { return [] }
        return detector.features(in: image).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
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
