//
//  GateEngine.swift
//  CamGate — Frontkamera-Gate-Pruefer (Gates spiegeln Incode-Konfiguration aus bunq)
//
import Foundation
import Vision
import CoreGraphics
import CoreVideo

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
// Achtung Apple-Konvention: yaw>0 = Gesicht nach links (Bild); roll>0 = nach rechts kippen.
func poseFrom(_ obs: VNFaceObservation) -> (roll: Double, pitch: Double, yaw: Double) {
    let r2d = 180.0 / Double.pi
    let roll  = (obs.roll?.doubleValue  ?? 0) * r2d
    let yaw   = (obs.yaw?.doubleValue   ?? 0) * r2d
    let pitch = (obs.pitch?.doubleValue ?? 0) * r2d
    return (roll, pitch, yaw)
}

// === Augen-offen-Heuristik aus den Augen-Regionen ===
// VNFaceLandmarkRegion2D liefert Punktwolken (ungeordnet). Offenes Auge =
// Region hat erhebliche Hoehe relativ zur Breite; geschlossenes Auge kollabiert.
enum EyeOpen {
    static func minAspect(_ obs: VNFaceObservation, imageSize: CGSize) -> Double {
        guard let lm = obs.landmarks else { return 1.0 }
        let regions = [lm.leftEye, lm.rightEye].compactMap { $0 }
        guard !regions.isEmpty else { return 1.0 }
        var minAspect = 1.0
        for region in regions {
            let pts = region.pointsInImage(imageSize: imageSize)
            guard pts.count >= 3 else { continue }
            var minX = CGFloat.greatestFiniteMagnitude, maxX = -CGFloat.greatestFiniteMagnitude
            var minY = CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude
            for p in pts {
                minX = min(minX, p.x); maxX = max(maxX, p.x)
                minY = min(minY, p.y); maxY = max(maxY, p.y)
            }
            let w = maxX - minX, h = maxY - minY
            guard w > 1 else { continue }
            minAspect = min(minAspect, Double(h / w))
        }
        return minAspect
    }
}

// === Luminanz-Stats (Zentral-Crop) ===
func luminanceStats(_ buf: CVPixelBuffer) -> (mean: Double, sd: Double) {
    CVPixelBufferLockBaseAddress(buf, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(buf) else { return (0, 0) }
    let w = CVPixelBufferGetWidth(buf), h = CVPixelBufferGetHeight(buf)
    let bpr = CVPixelBufferGetBytesPerRow(buf)
    let fmt = CVPixelBufferGetPixelFormatType(buf)
    var sum = 0.0, sum2 = 0.0, n = 0.0
    let cw = w / 2, ch = h / 5
    let ox = (w - cw) / 2, oy = h / 10
    switch fmt {
    case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
        for y in (oy + ch/2)..<(oy + ch) {
            var x = ox
            while x < ox + cw {
                let l = Double(base.advanced(by: y*bpr + x).load(as: UInt8.self))
                sum += l; sum2 += l*l; n += 1
                x += 3
            }
        }
    case kCVPixelFormatType_32BGRA:
        for y in (oy + ch/2)..<(oy + ch) {
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
    let size = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
    v.earMin = EyeOpen.minAspect(obs, imageSize: size)
    (v.brightness, v.contrast) = luminanceStats(buffer)

    if abs(r) > Gates.rollMax { v.reason = String(format: "Roll %.1f° > %.0f°", r, Gates.rollMax) }
    else if abs(p) > Gates.pitchMax { v.reason = String(format: "Pitch %.1f° > %.0f°", p, Gates.pitchMax) }
    else if y < Gates.yawMin || y > Gates.yawMax { v.reason = String(format: "Yaw %.1f° außerhalb [%.0f,%.0f]", y, Gates.yawMin, Gates.yawMax) }
    else if v.faceWidth < Gates.minFaceWidth { v.reason = String(format: "Gesicht %.0fpx < %.0fpx — näher ran", v.faceWidth, Gates.minFaceWidth) }
    else if v.brightness < Gates.brightnessMin { v.reason = "Zu dunkel" }
    else if v.contrast < Gates.contrastMin { v.reason = "Zu flau/blurry" }
    else if v.earMin < Gates.earClosed { v.reason = "Augen zu" }
    return v
}
