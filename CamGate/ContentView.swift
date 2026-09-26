//
//  ContentView.swift
//  CamGate
//
import SwiftUI
import AVFoundation
import Vision

struct ContentView: View {
    @StateObject private var cam = CameraModel()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            CameraPreview(model: cam).ignoresSafeArea()
            VStack {
                Spacer()
                if let v = cam.verdict {
                    Text(v.ok ? "BEREIT — FRONTAL, GERADE, AUGEN AUF" : (v.reason ?? "…"))
                        .font(.headline).foregroundColor(v.ok ? .green : .red)
                        .multilineTextAlignment(.center)
                } else {
                    Text("SUCHE GESICHT…").font(.headline).foregroundColor(.orange)
                }
                InfoRow(v: cam.verdict, incode: cam.incodeResult)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 4)
                HStack(spacing: 10) {
                    Button(action: { cam.analyseFrame() }) {
                        Label("Analyse", systemImage: "camera.metering.center.weighted")
                            .font(.caption).padding(.vertical, 6).padding(.horizontal, 10)
                            .background(Color.blue.opacity(0.8)).cornerRadius(8)
                    }
                }
                .padding(.bottom, 8)
            }
        }
        .onAppear { cam.start() }
        .onDisappear { cam.stop() }
    }
}

struct InfoRow: View {
    let v: GateVerdict?
    let incode: IncodeInference.Result?
    private func f(_ x: Double, _ d: Int = 1) -> String { String(format: "%.\(d)f", x) }
    var body: some View {
        VStack(spacing: 4) {
            if let v = v {
                GateLine("Roll",   v.roll,   s: f(v.roll)+"°",   limit: Gates.rollMax)
                GateLine("Pitch",  v.pitch,  s: f(v.pitch)+"°",  limit: Gates.pitchMax)
                GateLine("Yaw",    v.yaw,    s: f(v.yaw)+"°",    limit: max(abs(Gates.yawMin), Gates.yawMax), lower: Gates.yawMin)
                GateLine("Face",   v.faceWidth, s: f(v.faceWidth,0)+"px", limit: Gates.minFaceWidth, minIsBad: true)
                GateLine("Licht",  v.brightness, s: f(v.brightness,0), limit: Gates.brightnessMin, minIsBad: true)
                GateLine("Schärfe",v.contrast, s: f(v.contrast,0), limit: Gates.contrastMin, minIsBad: true)
                GateLine("Augen",  v.earMin, s: f(v.earMin,2), limit: Gates.earClosed, minIsBad: true)
            }
            if let r = incode {
                Divider().overlay(Color.white.opacity(0.2))
                Text("Incode-Modelle").font(.caption2).foregroundColor(.cyan)
                if let e = r.error {
                    Text("Fehler: \(e)").font(.caption2).foregroundColor(.red)
                } else {
                    Text("Quality-Score: \(f(Double(r.qualityScore), 3))")
                        .font(.caption2).foregroundColor(.white)
                    Text("Attribute-Conf: \(r.attributeConf.map { String(format: "%.2f", $0) }.joined(separator: " / "))")
                        .font(.caption2).foregroundColor(.white)
                    Text("Occlusion: \(f(Double(r.occlusionRatio)*100,1))% verdeckt")
                        .font(.caption2).foregroundColor(r.occlusionRatio < 0.3 ? .green : .orange)
                }
            }
        }
        .font(.caption.monospacedDigit())
        .padding(10)
        .background(Color.black.opacity(0.55))
        .cornerRadius(10)
    }
}
struct GateLine: View {
    var name: String; var val: Double; var s: String; var limit: Double
    var lower: Double? = nil; var minIsBad = false
    init(_ name: String, _ val: Double, s: String, limit: Double, lower: Double? = nil, minIsBad: Bool = false) {
        self.name = name; self.val = val; self.s = s; self.limit = limit; self.lower = lower; self.minIsBad = minIsBad
    }
    private var ok: Bool {
        if let lo = lower { return val >= lo && val <= limit }
        if minIsBad { return val >= limit }
        return abs(val) <= limit
    }
    var body: some View {
        HStack { Text(name).foregroundColor(.white); Spacer(); Text(s).foregroundColor(ok ? .green : .red) }
    }
}

final class CameraModel: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    @Published var verdict: GateVerdict?
    @Published var incodeResult: IncodeInference.Result?

    private let queue = DispatchQueue(label: "camgate.vision", qos: .userInteractive)
    private lazy var visionRequests = Self.buildVisionRequests()
    private var dataOutput: AVCaptureVideoDataOutput?
    private var usedPosition: AVCaptureDevice.Position = .front
    private var configured = false
    private var lastPub: TimeInterval = 0
    private weak var previewLayer: AVCaptureVideoPreviewLayer?
    private var lastFaceBox: CGRect?
    private var lastBuffer: CVPixelBuffer?
    private var analysing = false

    static func buildVisionRequests() -> [VNRequest] {
        let detect = VNDetectFaceLandmarksRequest()
        detect.revision = VNDetectFaceLandmarksRequestRevision3
        let qual = VNDetectFaceCaptureQualityRequest()
        qual.revision = VNDetectFaceCaptureQualityRequestRevision2
        return [detect, qual]
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
        default:
            DispatchQueue.main.async { self.verdict = GateVerdict.fail("Kamera verweigert") }
            return
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
        if !session.isRunning {
            DispatchQueue.global(qos: .userInitiated).async { self.session.startRunning() }
        }
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

    func analyseFrame() {
        guard !analysing else { return }
        analysing = true
        defer { analysing = false }
        guard let buf = lastBuffer, let box = lastFaceBox else { return }
        let r = IncodeInference.run(buf, box: box)
        DispatchQueue.main.async { self.incodeResult = r }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let px = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ori: CGImagePropertyOrientation = (usedPosition == .front) ? .leftMirrored : .right
        let handler = VNImageRequestHandler(cvPixelBuffer: px, orientation: ori, options: [:])
        do { try handler.perform(visionRequests) } catch { return }
        guard let face = (visionRequests[0] as? VNDetectFaceLandmarksRequest)?.results?.first else {
            lastFaceBox = nil; lastBuffer = nil
            publish(nil); return
        }
        lastFaceBox = face.boundingBox
        lastBuffer = px
        let v = evaluate(obs: face, buffer: px)
        publish(v)
    }

    private func publish(_ v: GateVerdict?) {
        let now = Date().timeIntervalSince1970
        guard now - lastPub > 0.08 else { return }
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
