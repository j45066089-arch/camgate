//
//  IncodeModels.swift
//  CamGate — lädt Incodes eigene CoreML-Modelle (aus bunq entschlüsselt)
//
import Foundation
import CoreML
import CoreImage
import CoreVideo

enum IncodeInference {
    static let qualitySize = 112
    static let attributeSize = 160
    static let occlusionSize = 224

    struct Result {
        var qualityScore: Float = .nan
        var attributeConf: [Float] = []
        var attrLabel: Int = -1
        var occlusionRatio: Float = .nan
        var error: String?
    }

    private static let qualityModel: MLModel? = try? load("selfie_quality_model_v1_0_fp16")
    private static let attributeModel: MLModel? = try? load("face_attributes_v1_3_f16")
    private static let occlusionModel: MLModel? = try? load("face_occlusion_v0_2_f16")

    private static func load(_ name: String) throws -> MLModel {
        guard let url = Bundle.main.url(forResource: name, withExtension: "mlmodelc") else {
            throw NSError(domain: "CamGate", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(name).mlmodelc fehlt"])
        }
        return try MLModel(contentsOf: url)
    }

    // ---------- Preprocessing ----------
    // Incode-Schema: Face-Box (Vision, Origin unten-links) -> zentriert auf Face-Center,
    // Rand-Padding ~25%, quadratischer Crop, Resize auf Modellgröße, 0..1-Normalisierung.
    // Format pro Modell:
    //   selfie_quality : BGR  (qualityForBGRMat:)
    //   face_attributes: RGB  (attributesForRGBMat:)
    //   face_occlusion : RGB  (occlusionForRGBMat:)
    static func makeArray(buf: CVPixelBuffer, box: CGRect, size: Int, rgbOrder: [Int]) -> MLMultiArray? {
        let W = CVPixelBufferGetWidth(buf), H = CVPixelBufferGetHeight(buf)
        // Vision-Rect (Origin unten-links) -> Pixel-Rect (Origin oben-links)
        let x0 = box.origin.x * CGFloat(W)
        let y0 = (1.0 - box.origin.y - box.height) * CGFloat(H)
        let w0 = box.width * CGFloat(W)
        let h0 = box.height * CGFloat(H)

        // Quadrat um Face-Center mit 25% Padding
        let cx = x0 + w0/2, cy = y0 + h0/2
        let side = max(w0, h0) * 1.25
        var crop = CGRect(x: cx - side/2, y: cy - side/2, width: side, height: side)
        crop = crop.intersection(CGRect(x: 0, y: 0, width: W, height: H))
        guard crop.width > 4, crop.height > 4 else { return nil }

        let ci = CIImage(cvPixelBuffer: buf)
        var img = ci.cropped(to: crop)

        // Auf Zielgröße skalieren (quadratisch: einfach gleichförmig)
        let target = CGFloat(size)
        let sx = target / img.extent.width
        let sy = target / img.extent.height
        img = img.transformed(by: CGAffineTransform(scaleX: sx, y: sy))

        let ctx = CIContext(options: [.workingColorSpace: NSNull(), .cacheIntermediates: false])
        var rgba = [UInt8](repeating: 0, count: size*size*4)
        ctx.render(img, toBitmap: &rgba, rowBytes: size*4,
                   bounds: CGRect(x: 0, y: 0, width: target, height: target),
                   format: .RGBA8, colorSpace: nil)

        // [1,3,H,W] Float32 CHW
        let shape: [NSNumber] = [1, 3, NSNumber(value: size), NSNumber(value: size)]
        guard let arr = try? MLMultiArray(shape: shape, dataType: .float32) else { return nil }
        let p = arr.dataPointer.bindMemory(to: Float.self, capacity: arr.count)
        var idx = 0
        for cIdx in 0..<3 {
            let c = rgbOrder[cIdx]
            for y in 0..<size {
                for x in 0..<size {
                    p[idx] = Float(rgba[(y*size + x)*4 + c]) / 255.0
                    idx += 1
                }
            }
        }
        return arr
    }

    static func run(_ buf: CVPixelBuffer, box: CGRect) -> Result {
        var r = Result()

        // 1) Quality (BGR, 112)
        if let m = qualityModel, let arr = makeArray(buf: buf, box: box, size: qualitySize, rgbOrder: [2,1,0]) {
            do {
                let out = try m.prediction(from: MLDictionaryFeatureProvider(dictionary: ["input": MLFeatureValue(multiArray: arr)]))
                if let scores = out.featureValue(for: "scores")?.multiArrayValue {
                    let p = scores.dataPointer.bindMemory(to: Float.self, capacity: scores.count)
                    var sum: Float = 0
                    for i in 0..<scores.count { sum += p[i] }
                    r.qualityScore = sum / Float(scores.count)
                } else {
                    r.error = (r.error ?? "") + " quality: kein Output"
                }
            } catch {
                r.error = (r.error ?? "") + " quality: \(error.localizedDescription)"
            }
        } else if qualityModel == nil { r.error = "quality-Modell fehlt" }

        // 2) Attributes (RGB, 160)
        if let m = attributeModel, let arr = makeArray(buf: buf, box: box, size: attributeSize, rgbOrder: [0,1,2]) {
            do {
                let out = try m.prediction(from: MLDictionaryFeatureProvider(dictionary: ["input": MLFeatureValue(multiArray: arr)]))
                if let conf = out.featureValue(for: "output_conf")?.multiArrayValue {
                    let p = conf.dataPointer.bindMemory(to: Float.self, capacity: conf.count)
                    r.attributeConf = (0..<conf.count).map { p[$0] }
                    r.attrLabel = r.attributeConf.enumerated().max(by: { $0.element < $1.element })?.offset ?? -1
                } else {
                    r.error = (r.error ?? "") + " attr: kein Output"
                }
            } catch {
                r.error = (r.error ?? "") + " attr: \(error.localizedDescription)"
            }
        } else if attributeModel == nil { r.error = "attr-Modell fehlt" }

        // 3) Occlusion (RGB, 224) — Input-Shape laut metadata: [3,224,224] (OHNE Batch)
        if let m = occlusionModel, let arr = makeArray(buf: buf, box: box, size: occlusionSize, rgbOrder: [0,1,2]) {
            // CoreML akzeptiert für MLMultiArray-Input die exakt deklarierte Shape.
            // Falls [1,3,H,W] abgelehnt wird, versuchen wir [3,H,W].
            func runOcclusion(_ input: MLMultiArray) throws -> Float? {
                let out = try m.prediction(from: MLDictionaryFeatureProvider(dictionary: ["input": MLFeatureValue(multiArray: input)]))
                guard let mask = out.featureValue(for: "output")?.multiArrayValue else { return nil }
                let p = mask.dataPointer.bindMemory(to: Float.self, capacity: mask.count)
                let n = mask.count
                // [1,1,2,224,224] oder [2,224,224]: Kanal-Layout ermitteln
                if n >= 2 {
                    let per = n / 2
                    var occ: Float = 0
                    for i in 0..<per {
                        if p[i + per] > p[i] { occ += 1 }
                    }
                    return occ / Float(per)
                }
                return nil
            }
            do {
                if let ratio = try runOcclusion(arr) {
                    r.occlusionRatio = ratio
                } else {
                    r.error = (r.error ?? "") + " occl: kein Output"
                }
            } catch {
                // Fallback: [3,H,W]
                let shape: [NSNumber] = [3, NSNumber(value: occlusionSize), NSNumber(value: occlusionSize)]
                if let arr3 = try? MLMultiArray(shape: shape, dataType: .float32) {
                    let src = arr.dataPointer.bindMemory(to: Float.self, capacity: arr.count)
                    let dst = arr3.dataPointer.bindMemory(to: Float.self, capacity: arr3.count)
                    for i in 0..<arr3.count { dst[i] = src[i] }
                    do {
                        if let ratio = try runOcclusion(arr3) {
                            r.occlusionRatio = ratio
                        }
                    } catch {
                        r.error = (r.error ?? "") + " occl: \(error.localizedDescription)"
                    }
                }
            }
        } else if occlusionModel == nil { r.error = "occl-Modell fehlt" }

        return r
    }
}
