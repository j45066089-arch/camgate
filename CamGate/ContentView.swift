//
//  ContentView.swift
//  CamGate — Incode Selfie-Verifikation (Kopie)
//
import SwiftUI
import AVFoundation
import Vision

enum CamState {
    case idle, scanning, capturing, done
}

struct ContentView: View {
    @StateObject private var cam = CameraModel()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            CameraPreview(model: cam).ignoresSafeArea()

            switch cam.state {
            case .idle:
                TutorialView { cam.beginScanning() }
            case .scanning:
                ScanningView(model: cam)
            case .capturing:
                CapturingView()
            case .done:
                ResultView(
                    verdict: cam.finalVerdict ?? GateVerdict.fail("Unbekannt"),
                    incode: cam.finalIncode,
                    onRetry: { cam.beginScanning() },
                    onRestart: { cam.resetToIdle() }
                )
            }
        }
        .onAppear { cam.start() }
        .onDisappear { cam.stop() }
    }
}

// MARK: - Tutorial
struct TutorialView: View {
    let onStart: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 14) {
                Text("Selfie aufnehmen")
                    .font(.title2).bold().foregroundColor(.white)
                Text("Neutral bleiben, gute Beleuchtung, keine Brille oder Mütze")
                    .font(.subheadline).foregroundColor(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
                Text("Telefon in Armlänge vor das Gesicht halten, Aufnahme erfolgt automatisch")
                    .font(.footnote).foregroundColor(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .background(Color.black.opacity(0.55)).cornerRadius(16)
            Spacer()
            Button(action: onStart) {
                Text("Selfie aufnehmen")
                    .font(.headline).foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.white).cornerRadius(12)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 30)
        }
    }
}

// MARK: - Live-Scanning
struct ScanningView: View {
    @ObservedObject var model: CameraModel

    var body: some View {
        VStack {
            Spacer()
            ZStack {
                Ellipse()
                    .stroke(Color.white, lineWidth: 3)
                    .frame(width: 190, height: 250)
                if let v = model.verdict, v.ok {
                    Ellipse().stroke(Color.green, lineWidth: 3).frame(width: 190, height: 250)
                }
            }
            .padding(.bottom, 20)

            Text(feedbackText)
                .font(.headline).foregroundColor(feedbackColor)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.bottom, 6)

            if let v = model.verdict {
                Text("Roll \(String(format: "%.1f", v.roll))° · Yaw \(String(format: "%.1f", v.yaw))° · Face \(Int(v.faceWidth))px")
                    .font(.caption2).foregroundColor(.white.opacity(0.6))
                    .padding(.bottom, 24)
            }
        }
    }

    private var feedbackColor: Color {
        if let v = model.verdict { return v.ok ? .green : .orange }
        return .orange
    }
    private var feedbackText: String {
        guard let v = model.verdict else { return IncodeText.faceNotFound }
        if v.ok { return IncodeText.getReady }
        return v.reason ?? IncodeText.unknown
    }
}

// MARK: - Capture
struct CapturingView: View {
    var body: some View {
        VStack {
            Spacer()
            ProgressView().tint(.white).scaleEffect(1.4)
                .padding(.bottom, 20)
            Text(IncodeText.capturing)
                .font(.title3).bold().foregroundColor(.white)
                .multilineTextAlignment(.center)
                .padding(24)
                .background(Color.black.opacity(0.55)).cornerRadius(16)
            Spacer()
        }
    }
}

// MARK: - Ergebnis
struct ResultView: View {
    let verdict: GateVerdict
    let incode: IncodeInference.Result?
    let onRetry: () -> Void
    let onRestart: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            if verdict.ok {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 64)).foregroundColor(.green)
                Text("Gesicht erfasst!")
                    .font(.title2).bold().foregroundColor(.white)
            } else {
                Image(systemName: "xmark.circle.fill").font(.system(size: 64)).foregroundColor(.red)
                Text(verdict.reason ?? "Fehler")
                    .font(.title2).bold().foregroundColor(.red)
                    .multilineTextAlignment(.center)
                Text("Selfie konnte nicht verarbeitet werden")
                    .font(.subheadline).foregroundColor(.white.opacity(0.7))
            }
            Spacer()
            if let incode = incode {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Incode-Analyse").font(.caption).bold().foregroundColor(.cyan)
                    if incode.errors.isEmpty {
                        Text("Quality-Score: \(String(format: "%.3f", incode.qualityScore))")
                            .font(.caption).foregroundColor(.white)
                        Text("Attribute: \(incode.attributeConf.map { String(format: "%.2f", $0) }.joined(separator: " / "))")
                            .font(.caption).foregroundColor(.white)
                        Text("Occlusion: \(String(format: "%.1f", incode.occlusionRatio * 100))% verdeckt")
                            .font(.caption).foregroundColor(incode.occlusionRatio < 0.3 ? .green : .orange)
                    } else {
                        ForEach(incode.errors, id: \.self) { e in
                            Text("⚠️ \(e)").font(.caption2).foregroundColor(.orange)
                        }
                    }
                }
                .padding(14).background(Color.black.opacity(0.55)).cornerRadius(12)
            }
            Spacer()
            HStack(spacing: 14) {
                Button(action: onRetry) {
                    Text("Nochmal").font(.headline).foregroundColor(.black)
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                        .background(Color.white).cornerRadius(12)
                }
                Button(action: onRestart) {
                    Text("Zurück").font(.headline).foregroundColor(.white)
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                        .background(Color.white.opacity(0.2)).cornerRadius(12)
                }
            }
            .padding(.horizontal, 20).padding(.bottom, 30)
        }
    }
}

// MARK: - Camera-Model (State-Machine)
final class CameraModel: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    @Published var state: CamState = .idle
    @Published var verdict: GateVerdict?
    @Published var finalVerdict: GateVerdict?
    @Published var finalIncode: IncodeInference.Result?

    private let queue = DispatchQueue(label: "camgate.vision", qos: .userInteractive)
    private lazy var visionRequests = Self.buildVisionRequests()
    private var usedPosition: AVCaptureDevice.Position = .front
    private var configured = false
    private var lastPub: TimeInterval = 0
    private var okSince: Date?
    private var captureInProgress = false
    private var running = false

    static func buildVisionRequests() -> [VNRequest] {
        let detect = VNDetectFaceLandmarksRequest()
        detect.revision = VNDetectFaceLandmarksRequestRevision3
        return [detect]
    }

    func start() {
        if configured && session.isRunning { return }
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized: break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { _ in DispatchQueue.main.async { self.start() } }
            return
        default: return
        }
        if session.inputs.isEmpty {
            session.beginConfiguration()
            session.sessionPreset = .hd1280x720
            guard let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
                  let input = try? AVCaptureDeviceInput(device: dev), session.canAddInput(input) else {
                session.commitConfiguration(); return
            }
            usedPosition = dev.position
            session.addInput(input)
            let out = AVCaptureVideoDataOutput()
            out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
            out.setSampleBufferDelegate(self, queue: queue)
            if session.canAddOutput(out) { session.addOutput(out) }
            session.commitConfiguration()
            configured = true
        }
        if !session.isRunning {
            DispatchQueue.global(qos: .userInitiated).async {
                self.session.startRunning()
                self.running = true
            }
        }
    }

    func beginScanning() {
        okSince = nil
        captureInProgress = false
        finalVerdict = nil
        finalIncode = nil
        DispatchQueue.main.async { self.state = .scanning }
    }

    func resetToIdle() {
        DispatchQueue.main.async { self.state = .idle }
    }

    func stop() { if session.isRunning { session.stopRunning() } }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let px = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ori: CGImagePropertyOrientation = (usedPosition == .front) ? .leftMirrored : .right
        let handler = VNImageRequestHandler(cvPixelBuffer: px, orientation: ori, options: [:])
        do { try handler.perform(visionRequests) } catch { return }
        guard let face = (visionRequests[0] as? VNDetectFaceLandmarksRequest)?.results?.first else {
            okSince = nil
            publish(GateVerdict.fail(IncodeText.faceNotFound))
            return
        }
        let v = evaluateLive(obs: face, buffer: px)
        publish(v)

        // Auto-Capture: Gates 1.8s stabil OK
        if state == .scanning && !captureInProgress {
            if v.ok {
                if okSince == nil { okSince = Date() }
                else if Date().timeIntervalSince(okSince!) >= 1.8 {
                    triggerCapture(px, box: face.boundingBox, verdict: v)
                }
            } else {
                okSince = nil
            }
        }
    }

    private func triggerCapture(_ buf: CVPixelBuffer, box: CGRect, verdict v: GateVerdict) {
        captureInProgress = true
        DispatchQueue.main.async { self.state = .capturing }
        let incode = IncodeInference.run(buf, box: box)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            self.finalVerdict = v
            self.finalIncode = incode
            self.state = .done
        }
    }

    private func publish(_ v: GateVerdict?) {
        let now = Date().timeIntervalSince1970
        guard now - lastPub > 0.1 else { return }
        lastPub = now
        DispatchQueue.main.async { self.verdict = v }
    }
}

// MARK: - Preview (konstant gespiegelt via Layer-Transform — kein Connection-Flicker)
struct CameraPreview: UIViewRepresentable {
    class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
    let model: CameraModel
    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.previewLayer.session = model.session
        v.previewLayer.videoGravity = .resizeAspectFill
        // Frontkamera: einmal spiegeln, konstant. Kein automaticallyAdjusts* — das war der Flicker.
        v.previewLayer.transform = CATransform3DMakeScale(-1, 1, 1)
        return v
    }
    func updateUIView(_ uiView: PreviewView, context: Context) {}
}
