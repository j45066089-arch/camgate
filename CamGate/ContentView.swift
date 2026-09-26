//
//  ContentView.swift
//  CamGate
//
import SwiftUI
import AVFoundation

struct ContentView: View {
    @StateObject private var cam = CameraModel()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            CameraPreview(session: cam.session)
                .ignoresSafeArea()
            VStack {
                Spacer()
                if let v = cam.verdict {
                    if v.ok {
                        Text("BEREIT — FRONTAL, GERADE, AUGEN AUF")
                            .font(.headline).foregroundColor(.green)
                    } else {
                        Text(v.reason ?? "…")
                            .font(.headline).foregroundColor(.red)
                    }
                } else {
                    Text("SUCHE GESICHT…").font(.headline).foregroundColor(.orange)
                }
                InfoRow(v: cam.verdict)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }
        }
        .onAppear { cam.start() }
        .onDisappear { cam.stop() }
    }
}

struct InfoRow: View {
    let v: GateVerdict?
    private func f(_ x: Double, _ d: Int = 1) -> String { String(format: "%.\(d)f", x) }
    var body: some View {
        VStack(spacing: 4) {
            if let v = v {
                Group {
                    GateLine("Roll",   v.roll,   s: f(v.roll)+"°",   limit: Gates.rollMax)
                    GateLine("Pitch",  v.pitch,  s: f(v.pitch)+"°",  limit: Gates.pitchMax)
                    GateLine("Yaw",    v.yaw,    s: f(v.yaw)+"°",    limit: max(abs(Gates.yawMin), Gates.yawMax), lower: Gates.yawMin)
                    GateLine("Face",   v.faceWidth, s: f(v.faceWidth,0)+"px", limit: Gates.minFaceWidth, minIsBad: true)
                    GateLine("Licht",  v.brightness, s: f(v.brightness,0), limit: Gates.brightnessMin, minIsBad: true)
                    GateLine("Schärfe",v.contrast, s: f(v.contrast,0), limit: Gates.contrastMin, minIsBad: true)
                    GateLine("Augen",  v.earMin, s: f(v.earMin,2), limit: Gates.earClosed, minIsBad: true)
                }
            } else {
                Text("—").foregroundColor(.gray)
            }
        }
        .font(.caption.monospacedDigit())
        .padding(10)
        .background(Color.black.opacity(0.55))
        .cornerRadius(10)
    }
}
struct GateLine: View {
    let name: String
    let val: Double
    let s: String
    let limit: Double
    var lower: Double? = nil
    var minIsBad = false
    private var ok: Bool {
        if let lo = lower { return val >= lo && val <= limit }
        if minIsBad { return val >= limit }
        return abs(val) <= limit
    }
    var body: some View {
        HStack {
            Text(name).foregroundColor(.white)
            Spacer()
            Text(s)
                .foregroundColor(ok ? .green : .red)
                .bold(ok == false)
        }
    }
}

final class CameraModel: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    @Published var verdict: GateVerdict?

    private let queue = DispatchQueue(label: "camgate.vision", qos: .userInteractive)
    private lazy var visionRequests = Self.buildVisionRequests()

    static func buildVisionRequests() -> [VNRequest] {
        let detect = VNDetectFaceLandmarksRequest()
        detect.revision = VNDetectFaceLandmarksRequestRevision3
        let qual = VNDetectFaceCaptureQualityRequest()
        qual.revision = VNDetectFaceCaptureQualityRequestRevision2
        return [detect, qual]
    }

    func start() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized: break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async { self.start() }
            }
            return
        default:
            DispatchQueue.main.async { self.verdict = GateVerdict.fail("Kamera verweigert — Einstellungen") }
            return
        }
        session.beginConfiguration()
        session.sessionPreset = .hd1280x720
        guard let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
              let input = try? AVCaptureDeviceInput(device: dev),
              session.canAddInput(input) else { return }
        session.addInput(input)
        let out = AVCaptureVideoDataOutput()
        out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        out.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(out) { session.addOutput(out) }
        session.commitConfiguration()
        DispatchQueue.global(qos: .userInitiated).async {
            self.session.startRunning()
        }
    }
    func stop() { session.stopRunning() }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let px = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let handler = VNImageRequestHandler(cvPixelBuffer: px, orientation: .up, options: [:])
        do {
            try handler.perform(visionRequests)
        } catch { return }
        guard let face = (visionRequests[0] as? VNDetectFaceLandmarksRequest)?.results?.first else {
            DispatchQueue.main.async { self.verdict = nil }
            return
        }
        let v = evaluate(obs: face, buffer: px)
        DispatchQueue.main.async { self.verdict = v }
    }
}

struct CameraPreview: UIViewRepresentable {
    class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
    let session: AVCaptureSession
    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspectFill
        return v
    }
    func updateUIView(_ uiView: PreviewView, context: Context) {}
}
