//
//  GateEngine.swift
//  CamGate — Frontkamera-Gate-Pruefer (Gates spiegeln Incode-Konfiguration aus bunq)
//
import Foundation
import Vision
import CoreGraphics

// === Gates ===
struct Gates {
    static let rollMax      = 8.0      // faceZAngleThreshold
    static let pitchMax     = 8.0      // faceYAngleMin/Max
    static let yawMin       = -12.0    // faceXAngleMinThreshold
    static let yawMax       = 17.0     // faceXAngleMaxThreshold
    static let minFaceWidth = 280.0    // minFaceSize @ 720p-Referenz
    static let brightnessMin: Double = 85
    static let contrastMin: Double   = 25
    static let earClosed             = 0.18
    static let refWidth: Double      = 720.0
}

struct GateVerdict {
    var roll = 0.0, pitch = 0.0, yaw = 0.0
    var faceWidth = 0.0
    var brightness = 0.0, contrast = 0.0
    var earMin = 1.0
    var reason: String? = nil
    var ok: Bool { reason == nil }

    static func fail(_ txt: String) -> GateVerdict {
        var v = GateVerdict(); v.reason = txt; return v
    }
}

// === Pose aus VNFaceObservation (Radiant -> Grad) ===
func poseFrom(_ obs: VNFaceObservation) -> (roll: Double, pitch: Double, yaw: Double) {
    let r2d = 180.0 / Double.pi
    let roll  = (obs.roll?.doubleValue  ?? 0) * r2d
    let yaw   = (obs.yaw?.doubleValue   ?? 0) * r2d
    let pitch = (obs.pitch?.doubleValue ?? 0) * r2d
    return (roll, pitch, yaw)
}

// === EAR ueber iBUG-68-Indizes (Vision-68-Konvention) ===
// Rechtes Auge: 42..47 (42 inner, 45 aussen, obere 43/44, untere 47/46)
// Linkes Auge:  36..41 (36 aussen, 39 inner, obere 37/38, untere 41/40)
func eyeRatio(inner: Int, outer: Int, upperA: Int, upperB: Int, lowerA: Int, lowerB: Int,
              geometry: VNFaceGeometry) -> Double {
    guard let pIn = geometry.point(inner), let pOut = geometry.point(outer) else { return 1 }
    let horiz = simdDistance(pIn, pOut)
    guard horiz > 1e-6 else { return 1 }
    guard let uA = geometry.point(upperA), let uB = geometry.point(upperB),
          let lA = geometry.point(lowerA), let lB = geometry.point(lowerB) else { return 1 }
    let vert = (simdDistance(uA, lA) + simdDistance(uB, lB)) / 2
    return vert / horiz
}

// Bei fehlender Landmark-Lieferung: EAR=1 (offen) — KEIN False-Fail.
enum FaceGeometryReader {
    static func minEAR(_ obs: VNFaceObservation) -> Double {
        guard let lm = obs.landmarks else { return 1.0 }
        guard let geo = VNFaceGeometry(observations: lm) else { return 1.0 }
        let r = eyeRatio(inner: 42, outer: 45, upperA: 43, upperB: 44, lowerA: 47, lowerB: 46, geometry: geo)
        let l = eyeRatio(inner: 39, outer: 36, upperA: 37, upperB: 38, lowerA: 41, lowerB: 40, geometry: geo)
        return min(r, l)
    }
}

// === Bild-Auswertung ===
func luminanceStats(_ buf: CVPixelBuffer) -> (mean: Double, sd: Double) {
    CVPixelBufferLockBaseAddress(buf, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(buf) else { return (0, 0) }
    let w = CVPixelBufferGetWidth(buf), h = CVPixelBufferGetHeight(buf)
    let bpr = CVPixelBufferGetBytesPerRow(buf)
    let fmt = CVPixelBufferGetPixelFormatType(buf)
    var sum = 0.0, sum2 = 0.0, n = 0.0
    // Nur Zentral-Crop (Gesichtszone)
    let cw = min(w, w / 2), ch = min(h, h / 5)
    let ox = (w - cw) / 2, oy = h / 10
    switch fmt {
    case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
        for y in oy..<(oy+ch) {
            var x = ox
            while x < ox + cw {
                let l = Double(base.advanced(by: y*bpr + x).load(as: UInt8.self))
                sum += l; sum2 += l*l; n += 1
                x += 3
            }
        }
    case kCVPixelFormatType_32BGRA:
        for y in oy..<(oy+ch) {
            var x = ox
            while x < ox + cw {
                let p = base.advanced(by: y*bpr + x*4)
                let b = Double(p.load(as: UInt8.self))
                let g = Double(p.advanced(by: 1).load(as: UInt8.self))
                let r = Double(p.advanced(by: 2).load(as: UInt8.self))
                let l = 0.299*r + 0.587*g + 0.114*b
                sum += l; sum2 += l*l; n += 1
                x += 3
            }
        }
    default: break
    }
    guard n > 0 else { return (0, 0) }
    let mean = sum / n
    let sd = sqrt(max(0, sum2/n - mean*mean))
    return (mean, sd)
}

// === Haupt-Gate-Pruefung ===
func evaluate(obs: VNFaceObservation, buffer: CVPixelBuffer) -> GateVerdict {
    var v = GateVerdict()
    let (r, p, y) = poseFrom(obs)
    v.roll = r; v.pitch = p; v.yaw = y
    v.faceWidth = Double(obs.boundingBox.width) * Gates.refWidth
    v.earMin = FaceGeometryReader.minEAR(obs)
    (v.brightness, v.contrast) = luminanceStats(buffer)

    if abs(r) > Gates.rollMax    { v.reason = String(format: "Roll %.1f° > %.0f°", r, Gates.rollMax) }
    else if abs(p) > Gates.pitchMax { v.reason = String(format: "Pitch %.1f° > %.0f°", p, Gates.pitchMax) }
    else if y < Gates.yawMin || y > Gates.yawMax { v.reason = String(format: "Yaw %.1f° außerhalb [%.0f,%.0f]", y, Gates.yawMin, Gates.yawMax) }
    else if v.faceWidth < Gates.minFaceWidth { v.reason = String(format: "Gesicht %.0fpx < %.0fpx — näher ran", v.faceWidth, Gates.minFaceWidth) }
    else if v.brightness < Gates.brightnessMin { v.reason = "Zu dunkel" }
    else if v.contrast < Gates.contrastMin { v.reason = "Zu flau/blurry" }
    else if v.earMin < Gates.earClosed { v.reason = "Augen zu" }
    return v
}

struct VNFaceGeometry {
    let pts: [SIMD2<Double>]
    init?(observations: VNFaceLandmarks2D, in faceSize: CGSize = CGSize(width: 720, height: 1280)) {
        guard let region = try? observations.pointsInFaceSpace(faceSize) else { return nil }
        let c = region.count
        guard c >= 68 else { return nil }
        pts = (0..<c).map { i -> SIMD2<Double> in
            let p = region[i]
            return SIMD2<Double>(Double(p.x), Double(p.y))
        }
    }
    func point(_ i: Int) -> SIMD2<Double>? {
        guard i >= 0 && i < pts.count else { return nil }
        return pts[i]
    }
}
func simdDistance(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
    let dx = a.x-b.x, dy = a.y-b.y
    return sqrt(dx*dx + dy*dy)
}
