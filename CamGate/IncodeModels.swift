//
//  IncodeModels.swift
//  CamGate — Incodes echte Modelle + korrekte Koordinaten-Mapping
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
        var occlusionRatio: Float = .nan
        var errors: [String] = []
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

    // KORREKTE Koordinaten-Transformation:
    // Buffer ist landscape (rawW x rawH). Vision-Handler bekommt .leftMirrored =>
    // die Box liegt im UPRIGHT-Bildraum (Breite=rawH, Höhe=rawW) als TRANSPOSE.
    // Raw-Pixel (px,py) = (uy, ux).
    static func makeArray(buf: CVPixelBuffer, box: CGRect, size: Int, batched: Bool, rgbOrder: [Int]) -> MLMultiArray? {
        let rawW = CGFloat(CVPixelBufferGetWidth(buf))    // 1280
        let rawH = CGFloat(CVPixelBufferGetHeight(buf))   // 720

        // Upright-Bildraum: Breite = rawH, Hoehe = rawW
        let ux0 = box.origin.x * rawH
        let uy0 = (1.0 - box.origin.y - box.height) * rawW
        let uw  = box.width * rawH
        let uh  = box.height * rawW

        // Transpose -> Raw-Pixel-Rechteck (Top-Left-Ursprung)
        let pxX = uy0
        let pxY = ux0
        let pxW = uh
        let pxH = uw

        // Quadratischer Center-Crop mit 20% Padding
        let cx = pxX + pxW/2, cy = pxY + pxH/2
        let side = max(pxW, pxH) * 1.2
        var crop = CGRect(x: cx - side/2, y: cy - side/2, width: side, height: side)
        crop = crop.intersection(CGRect(x: 0, y: 0, width: rawW, height: rawH))
        guard crop.width > 4, crop.height > 4 else { return nil }

        let ci = CIImage(cvPixelBuffer: buf)
        // CIImage-Origin ist unten-links -> Y flippen
        let ciRect = CGRect(x: crop.origin.x,
                            y: rawH - crop.origin.y - crop.height,
                            width: crop.width, height: crop.height)
        var img = ci.cropped(to: ciRect)
        let s = CGFloat(size) / crop.width
        img = img.transformed(by: CGAffineTransform(scaleX: s, y: s))

        let ctx = CIContext(options: [.workingColorSpace: NSNull(), .cacheIntermediates: false])
        var rgba = [UInt8](repeating: 0, count: size*size*4)
        ctx.render(img, toBitmap: &rgba, rowBytes: size*4,
                   bounds: CGRect(x: 0, y: 0, width: CGFloat(size), height: CGFloat(size)),
                   format: .RGBA8, colorSpace: nil)

        var shape: [NSNumber]
        if batched { shape = [1, 3, NSNumber(value: size), NSNumber(value: size)] }
        else       { shape = [3, NSNumber(value: size), NSNumber(value: size)] }
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

        if let m = qualityModel, let arr = makeArray(buf: buf, box: box, size: qualitySize, batched: true, rgbOrder: [2,1,0]) {
            do {
                let out = try m.prediction(from: MLDictionaryFeatureProvider(dictionary: ["input": MLFeatureValue(multiArray: arr)]))
                if let scores = out.featureValue(for: "scores")?.multiArrayValue {
                    let p = scores.dataPointer.bindMemory(to: Float.self, capacity: scores.count)
                    if scores.count == 1 { r.qualityScore = p[0] }
                    else { var m: Float = 0; for i in 0..<scores.count { m += p[i] }; r.qualityScore = m / Float(scores.count) }
                } else { r.errors.append("quality: kein 'scores'") }
            } catch { r.errors.append("quality: \(error.localizedDescription)") }
        } else if qualityModel == nil { r.errors.append("quality-Modell fehlt") }

        if let m = attributeModel, let arr = makeArray(buf: buf, box: box, size: attributeSize, batched: true, rgbOrder: [0,1,2]) {
            do {
                let out = try m.prediction(from: MLDictionaryFeatureProvider(dictionary: ["input": MLFeatureValue(multiArray: arr)]))
                if let conf = out.featureValue(for: "output_conf")?.multiArrayValue {
                    let p = conf.dataPointer.bindMemory(to: Float.self, capacity: conf.count)
                    r.attributeConf = (0..<conf.count).map { p[$0] }
                } else { r.errors.append("attr: kein 'output_conf'") }
            } catch { r.errors.append("attr: \(error.localizedDescription)") }
        } else if attributeModel == nil { r.errors.append("attr-Modell fehlt") }

        if let m = occlusionModel, let arr = makeArray(buf: buf, box: box, size: occlusionSize, batched: false, rgbOrder: [0,1,2]) {
            do {
                let out = try m.prediction(from: MLDictionaryFeatureProvider(dictionary: ["input": MLFeatureValue(multiArray: arr)]))
                if let mask = out.featureValue(for: "output")?.multiArrayValue {
                    let p = mask.dataPointer.bindMemory(to: Float.self, capacity: mask.count)
                    let per = mask.count / 2
                    if per > 0 {
                        var occ: Float = 0
                        for i in 0..<per { if p[i + per] > p[i] { occ += 1 } }
                        r.occlusionRatio = occ / Float(per)
                    } else { r.errors.append("occl: leeres Output") }
                } else { r.errors.append("occl: kein 'output'") }
            } catch { r.errors.append("occl: \(error.localizedDescription)") }
        } else if occlusionModel == nil { r.errors.append("occl-Modell fehlt") }

        return r
    }
}
