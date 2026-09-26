//
//  ContentView.swift
//  CamGate — Incode Selfie-Verifikation (Kopie: gleiche Gates, gleiche Texte, gleiche Modelle)
//
import SwiftUI
import AVFoundation
import Vision

// MARK: - Phasen des Incode-Flows
enum SelfiePhase {
    case tutorial          // "Selfie aufnehmen" Intro
    case scanning          // Live: Silhouette + Feedback
    case capturing         // "Nicht bewegen! Foto wird aufgenommen…"
    case result            // "Gesicht erfasst!" oder Fehlergrund
}

struct ContentView: View {
    @StateObject private var cam = CameraModel()
    @State private var phase: SelfiePhase = .tutorial

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            CameraPreview(model: cam).ignoresSafeArea()

            switch phase {
            case .tutorial:
                TutorialView {
                    phase = .scanning
                    cam.beginScanning()
                }
            case .scanning:
                ScanningView(model: cam) {
                    // Auto-Capture ausgelöst
                    phase = .capturing
                    cam.captureCurrentFrame()
                } onDone: { verdict, incode in
                    phase = .result
                }
            case .capturing:
                CapturingView(model: cam) { verdict, incode in
                    phase = .result
                }
            case .result:
                if let v = cam.finalVerdict {
                    ResultView(verdict: v, incode: cam.finalIncode, onRetry: {
                        phase = .scanning
                        cam.beginScanning()
                    }, onRestart: {
                        phase = .tutorial
                    })
                }
            }
        }
        .onAppear { cam.start() }
        .onDisappear { cam.stop() }
    }
}

// MARK: - Tutorial (exakt Incodes Texte)
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

// MARK: - Live-Scanning mit Silhouette + Incode-Feedback
struct ScanningView: View {
    @ObservedObject var model: CameraModel
    let onCapture: () -> Void
    let onDone: (GateVerdict?, IncodeInference.Result?) -> Void

    var body: some View {
        VStack {
            Spacer()
            // Silhouette (Oval)
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
        if v.ok { return IncodeText.captured }
        return v.reason ?? IncodeText.unknown
    }
}

// MARK: - Capture-Phase
struct CapturingView: View {
    @ObservedObject var model: CameraModel
    let onDone: (GateVerdict?, IncodeInference.Result?) -> Void
    var body: some View {
        VStack {
            Spacer()
            Text(IncodeText.capturing)
                .font(.title3).bold().foregroundColor(.white)
                .multilineTextAlignment(.center)
                .padding(24)
                .background(Color.black.opacity(0.55)).cornerRadius(16)
            Spacer()
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { onDone(model.finalVerdict, model.finalIncode) }
        }
    }
}

// MARK: - Ergebnis (End-Report: exakter Fehlergrund)
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
                    ForEach(incode.errors, id: \.self) { e in
                        Text("⚠️ \(e)").font(.caption2).foregroundColor(.orange)
                    }
                    if incode.errors.isEmpty {
                        Text("Quality-Score: \(String(format: "%.3f", incode.qualityScore))")
                            .font(.caption).foregroundColor(.white)
                        Text("Attribute: \(incode.attributeConf.map { String(format: "%.2f", $0) }.joined(separator: " / "))")
                            .font(.caption).foregroundColor(.white)
                        Text("Occlusion: \(String(format: "%.1f", incode.occlusionRatio * 100))% verdeckt")
                            .font(.caption).foregroundColor(incode.occlusionRatio < 0.3 ? .green : .orange)
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

// MARK: - Camera-Model
final class CameraModel: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    @Published var verdict: GateVerdict?
    @Published var finalVerdict: GateVerdict?
    @Published var finalIncode: IncodeInference.Result?

    private let queue = DispatchQueue(label: "camgate.vision", qos: .userInteractive)
    private lazy var visionRequests = Self.buildVisionRequests()
    private var dataOutput: AVCaptureVideoDataOutput?
    private var usedPosition: AVCaptureDevice.Position = .front
    private var configured = false
    private var lastPub: TimeInterval = 0
    private weak var previewLayer: AVCaptureVideoPreviewLayer?
    private var lastFaceBox: CGRect?
    private var lastBuffer: CVPixelBuffer?
    private var captureRequested = false

    static func buildVisionRequests() -> [VNRequest] {
        let detect = VNDetectFaceLandmarksRequest()
        detect.revision = VNDetectFaceLandmarksRequestRevision3
        return [detect]
    }

    func attachPreview(_ layer: AVCaptureVideoPreviewLayer) { previewLayer = layer; pinMirroring() }

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
            if session.canAddOutput(out) { session.addOutput(out); dataOutput = out }
            session.commitConfiguration()
            configured = true
        }
        pinMirroring()
        if !session.isRunning { DispatchQueue.global(qos: .userInitiated).async { self.session.startRunning() } }
    }

    func beginScanning() { finalVerdict = nil; finalIncode = nil }

    func captureCurrentFrame() {
        captureRequested = true
    }

    private func pinMirroring() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let c = self.previewLayer?.connection {
                c.automaticallyAdjustsVideoMirroring = false
                c.isVideoMirrored = (self.usedPosition == .front)
            }
            if let c = self.dataOutput?.connection(with: .video) {
                c.automaticallyAdjustsVideoMirroring = false
                c.isVideoMirrored = (self.usedPosition == .front)
            }
        }
    }

    func stop() { if session.isRunning { session.stopRunning() } }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let px = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ori: CGImagePropertyOrientation = (usedPosition == .front) ? .leftMirrored : .right
        let handler = VNImageRequestHandler(cvPixelBuffer: px, orientation: ori, options: [:])
        do { try handler.perform(visionRequests) } catch { return }
        guard let face = (visionRequests[0] as? VNDetectFaceLandmarksRequest)?.results?.first else {
            lastFaceBox = nil; lastBuffer = nil
            publish(GateVerdict.fail(IncodeText.faceNotFound)); return
        }
        lastFaceBox = face.boundingBox
        lastBuffer = px
        let v = evaluateLive(obs: face, buffer: px)
        publish(v)

        // Auto-Capture: wenn Gates OK und Capture angefordert
        if captureRequested && v.ok {
            captureRequested = false
            let incode = IncodeInference.run(px, box: face.boundingBox)
            DispatchQueue.main.async {
                self.finalVerdict = v
                self.finalIncode = incode
            }
        }
    }

    private func publish(_ v: GateVerdict?) {
        let now = Date().timeIntervalSince1970
        guard now - lastPub > 0.1 else { return }
        lastPub = now
        DispatchQueue.main.async { self.verdict = v }
    }
}

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
        model.attachPreview(v.previewLayer)
        return v
    }
    func updateUIView(_ uiView: PreviewView, context: Context) {}
}
