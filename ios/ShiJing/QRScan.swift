import Foundation
import SwiftUI

/// 扫电脑上「设置 › 手机遥控 › 扫码配对」显示的二维码。
/// 二维码里是 `shijing://pair?h=<IP>&p=<端口>&c=<配对码>`：扫到就拿配对码直接提交，
/// 电脑那边已经点过「显示二维码」了，不用再在电脑上确认。
struct QRScanView: View {
    let store: MacStore
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var error: String?
    /// 重新扫描：换一个 id 重建取景视图，之前的「扫到一次就停」也就复位了
    @State private var scanID = UUID()

    var body: some View {
        NavigationStack {
            ZStack {
                QRScannerRepresentable { text in
                    Task { await pair(text) }
                }
                .id(scanID)
                .ignoresSafeArea()

                VStack(spacing: 12) {
                    Spacer()
                    if busy {
                        ProgressView("正在配对…")
                            .padding(.horizontal, 18).padding(.vertical, 12)
                            .background(.ultraThinMaterial, in: Capsule())
                    } else if let error {
                        VStack(spacing: 10) {
                            Text(error)
                                .font(.subheadline)
                                .multilineTextAlignment(.center)
                            Button("重新扫描") {
                                self.error = nil
                                scanID = UUID()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .padding(18)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    } else {
                        Text("对准电脑上的配对二维码")
                            .font(.subheadline)
                            .padding(.horizontal, 18).padding(.vertical, 10)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    Spacer().frame(height: 30)
                }
                .padding(.horizontal, 24)
                .allowsHitTesting(error != nil && !busy)
            }
            .navigationTitle("扫描二维码")
            .iOSInlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            }
        }
    }

    /// 从二维码里取出地址和配对码。
    static func parse(_ text: String) -> (address: MacAddress, code: String)? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "shijing", url.host() == "pair",
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        func value(_ name: String) -> String? {
            comps.queryItems?.first { $0.name == name }?.value
        }
        guard let host = value("h"), !host.isEmpty,
              let portText = value("p"), let port = Int(portText), port > 0,
              let code = value("c"), code.count == 6 else { return nil }
        return (MacAddress(host: host, port: port), code)
    }

    private func pair(_ text: String) async {
        guard !busy else { return }
        guard let target = Self.parse(text) else {
            error = "这不是拾景的配对二维码。在电脑上打开拾景 › 设置 › 手机遥控 › 显示二维码。"
            return
        }
        busy = true
        defer { busy = false }
        do {
            let r = try await APIClient(address: target.address, token: nil)
                .pairFinish(code: target.code, device: PairView.defaultDeviceName)
            store.add(name: r.name, serviceName: nil, address: target.address, token: r.token)
            dismiss()
        } catch APIError.server(_, let msg) {
            error = msg
        } catch {
            self.error = RemoteSession.describe(error)
        }
    }
}

#if os(iOS)
import AVFoundation
import UIKit

/// 相机取景 + 二维码识别。扫到第一个二维码就停住，交给外面去配对。
private struct QRScannerRepresentable: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let vc = ScannerController()
        vc.onCode = onCode
        return vc
    }

    func updateUIViewController(_ vc: ScannerController, context: Context) {}
}

private final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    private let session = AVCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?
    private var fired = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            start()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] ok in
                DispatchQueue.main.async {
                    if ok { self?.start() } else { self?.showDenied() }
                }
            }
        default:
            showDenied()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    private func start() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            showDenied(camera: false)
            return
        }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            showDenied(camera: false)
            return
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        preview = layer

        // startRunning 会等相机准备好，别卡主线程
        Task.detached { [session] in session.startRunning() }
    }

    private func showDenied(camera: Bool = true) {
        let label = UILabel()
        label.text = camera
            ? "没有相机权限。到「设置 › 隐私与安全性 › 相机」里允许拾景使用相机，或者回电脑上用手动配对码。"
            : "这台设备用不了相机。回电脑上用手动配对码吧。"
        label.textColor = .white
        label.numberOfLines = 0
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),
        ])
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !fired,
              let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let text = obj.stringValue else { return }
        fired = true
        session.stopRunning()
        onCode?(text)
    }
}
#else
/// Mac 上做类型检查时用的占位（相机取景只在 iPhone 上有）。
private struct QRScannerRepresentable: View {
    let onCode: (String) -> Void
    var body: some View { Text("只在 iPhone 上可用") }
}
#endif
