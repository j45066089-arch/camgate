//
//  GateEngine.swift
//  CamGate — Incode-äquivalente Selfie-Gates (Schwellen aus bunq-Konfig)
//
import Foundation
import Vision
import CoreGraphics
import CoreVideo

struct Gates {
    static let rollMax      = 8.0      // faceZAngleThreshold
    static let pitchMax     = 8.0      // faceYAngleMin/Max
    static let yawMin       = -12.0    // faceXAngleMinThreshold
    static let yawMax       = 17.0     // faceXAngleMaxThreshold
    static let minFaceWidth = 280.0    // minFaceSize @ 720p
    static let brightnessMin: Double = 85
    static let contrastMin: Double   = 25
    static let earClosed             = 0.04
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

// ---- Incode-Original Texte (deutsch) für Fehlerfälle ----
enum IncodeText {
    static let badAngleXY  = "Geradeaus schauen"
    static let badAngleZ   = "Kopf nicht neigen"
    static let eyesClosed  = "Augen offen halten"
    static let faceOccluded = "Gesicht verdeckt"
    static let hasLenses   = "Brille abnehmen"
    static let hasFaceMask = "Maske abnehmen"
    static let hasHeadwear = "Mütze abnehmen"
    static let tooDark     = "Zu dunkel"
    static let tooBlurry   = "Zu unscharf"
    static let tooClose    = "Weiter weg gehen"
    static let tooFar      = "Näher herangehen"
    static let notAligned  = "Gesicht an Silhouette ausrichten"
    static let unknown     = "Kamera ansehen"
    static let faceNotFound = "Gesicht ausrichten und Kamera ansehen"
    static let lookCam     = "Gesicht an weißer Silhouette ausrichten"
    static let getReady    = "Bereit machen…"
    static let capturing   = "Nicht bewegen!\nFoto wird aufgenommen…"
    static let captured    = "Gesicht erfasst!"
    static let resultFail  = "Selfie konnte nicht verarbeitet werden"
}

func poseFrom(_ obs: VNFaceObservation) -> (roll: Double, pitch: Double, yaw: Double) {
    let r2d = 180.0 / Double.pi
    return ((obs.roll?.doubleValue ?? 0) * r2d,
            (obs.pitch?.doubleValue ?? 0) * r2d,
            (obs.yaw?.doubleValue ?? 0) * r2d)
}

func minEyeAspect(_ obs: VNFaceObservation, imageSize: CGSize) -> Double {
    guard let lm = obs.landmarks else { return 1.0 }
    let regions = [lm.leftEye, lm.rightEye].compactMap { $0 }
    guard !regions.isEmpty else { return 1.0 }
    var minAspect = 1.0
    for region in regions {
        let pts = region.pointsInImage(imageSize: imageSize)
        guard pts.count >= 3 else { continue }
        var minX = CGFloat.greatestFiniteMagnitude, maxX = -CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude
        for p in pts { minX = min(minX,p.x); maxX = max(maxX,p.x); minY = min(minY,p.y); maxY = max(maxY,p.y) }
        let w = maxX - minX, h = maxY - minY
        if w > 1 { minAspect = min(minAspect, Double(h / w)) }
    }
    return minAspect
}

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
                sum += l; sum2 += l*l; n += 1; x += 3
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
                sum += l; sum2 += l*l; n += 1; x += 3
            }
        }
    default: break
    }
    guard n > 0 else { return (0, 0) }
    let mean = sum / n
    return (mean, sqrt(max(0, sum2/n - mean*mean)))
}

// Erweiterte Bewertung mit Incode-Reason-Texten
func evaluateLive(obs: VNFaceObservation, buffer: CVPixelBuffer) -> GateVerdict {
    var v = GateVerdict()
    (v.roll, v.pitch, v.yaw) = poseFrom(obs)
    v.faceWidth = Double(obs.boundingBox.width) * Gates.refWidth
    let size = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
    v.earMin = minEyeAspect(obs, imageSize: size)
    (v.brightness, v.contrast) = luminanceStats(buffer)

    if abs(v.roll) > Gates.rollMax       { v.reason = IncodeText.badAngleZ }
    else if abs(v.pitch) > Gates.pitchMax { v.reason = IncodeText.badAngleXY }
    else if v.yaw < Gates.yawMin || v.yaw > Gates.yawMax { v.reason = IncodeText.badAngleXY }
    else if v.faceWidth < Gates.minFaceWidth { v.reason = (v.faceWidth < Gates.minFaceWidth * 0.6) ? IncodeText.tooFar : IncodeText.notAligned }
    else if v.brightness < Gates.brightnessMin { v.reason = IncodeText.tooDark }
    else if v.contrast < Gates.contrastMin { v.reason = IncodeText.tooBlurry }
    else if v.earMin < Gates.earClosed { v.reason = IncodeText.eyesClosed }
    return v
}

// Alias: alte Funktionsnamen weiter bedienen
func evaluate(obs: VNFaceObservation, buffer: CVPixelBuffer) -> GateVerdict {
    evaluateLive(obs: obs, buffer: buffer)
}
