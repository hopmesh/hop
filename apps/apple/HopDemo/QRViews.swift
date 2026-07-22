// QR identity exchange: reveal your own address as a QR, and scan another device's QR to add it as
// a contact. This is the explicit, in-person identity reveal that pairs with private mode: you stay
// anonymous on the mesh but can hand someone your address face-to-face.
import SwiftUI
import AVFoundation
import HopDriver
import HopDemoKit

// The QR payload format (HopQR) and the QR-bitmap builder now live in HopDemoKit so they are
// unit-tested headlessly; this file wraps the portable CGImage in a UIImage for SwiftUI.

func makeQRImage(_ text: String) -> UIImage? {
    guard let cg = DemoFormat.qrCGImage(text) else { return nil }
    return UIImage(cgImage: cg)
}

/// Show my address as a QR for someone else to scan.
struct QRRevealView: View {
    let address: String
    let name: String
    var body: some View {
        VStack(spacing: 16) {
            Text("My Hop code").font(.headline)
            if let img = makeQRImage(HopQR.encode(address: address, name: name)) {
                Image(uiImage: img).interpolation(.none).resizable().scaledToFit()
                    .frame(maxWidth: 280, maxHeight: 280)
            }
            Text(name).font(.title3)
            Text(address).font(.caption2).monospaced().foregroundStyle(.secondary)
                .textSelection(.enabled).multilineTextAlignment(.center).padding(.horizontal)
            Text("Have someone scan this to add you. Works even in private mode.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal)
            Spacer()
        }.padding()
    }
}

/// Camera QR scanner; calls onScan with the raw payload string once.
final class QRScannerVC: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onScan: ((String) -> Void)?
    private let session = AVCaptureSession()
    private var done = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.frame = view.bounds
        preview.videoGravity = .resizeAspectFill
        view.layer.addSublayer(preview)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.session.startRunning() }
    }
    override func viewDidLayoutSubviews() {
        (view.layer.sublayers?.first as? AVCaptureVideoPreviewLayer)?.frame = view.bounds
    }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if session.isRunning { session.stopRunning() }
    }
    func metadataOutput(_ o: AVCaptureMetadataOutput, didOutput objs: [AVMetadataObject], from c: AVCaptureConnection) {
        guard !done, let m = objs.first as? AVMetadataMachineReadableCodeObject, let s = m.stringValue else { return }
        done = true
        session.stopRunning()
        onScan?(s)
    }
}

struct QRScannerView: UIViewControllerRepresentable {
    let onScan: (String) -> Void
    func makeUIViewController(context: Context) -> QRScannerVC { let vc = QRScannerVC(); vc.onScan = onScan; return vc }
    func updateUIViewController(_ vc: QRScannerVC, context: Context) {}
}

/// Sheet that scans a QR and adds the contact, then dismisses.
struct QRScanSheet: View {
    @ObservedObject var bearer: HopBearer
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    var body: some View {
        ZStack(alignment: .bottom) {
            QRScannerView { payload in
                if let (addr, name) = HopQR.decode(payload), bearer.addContact(name: name, address: addr) {
                    dismiss()
                } else {
                    error = "Not a Hop code"
                }
            }.ignoresSafeArea()
            VStack {
                Text(error ?? "Point at a Hop QR code")
                    .padding(8).background(.ultraThinMaterial).clipShape(Capsule())
                Button("Cancel") { dismiss() }.padding(.bottom)
            }
        }
    }
}
