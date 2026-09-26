//
//  IncodeModels.swift
//  CamGate — lädt Incodes echte CoreML-Modelle + Align/Crop wie Incode
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
        var qualityScore: Float = .nan   // 0..1 regressor, hoeher = besser
        var attributeConf: [Float] = []  // 4 Klassen (neutral/brille/maske/kopfbed. — unkalibriert)
        var attrLabel: Int = -1
        var occlusionRatio: Float = .nan // Anteil verdeckter Pixel (argmax der 2-Kanal-Maske)
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

    // Vision-Box (normalisiert, Origin unten-links) -> quadratischer Center-Crop mit 20% Rand -> resize -> CHW Float32 0..1
    // rgb: [0,1,2] = RGB, [2,1,0] = BGR
    static func makeArray(buf: CVPixelBuffer, box: CGRect, size: Int, batched: Bool, rgbOrder: [Int]) -> MLMultiArray? {
        let W = CVPixelBufferGetWidth(buf), H = CVPixelBufferGetHeight(buf)
        // Vision -> Pixel-Rect (top-left)
        let x0 = box.origin.x * CGFloat(W)
        let y0 = (1.0 - box.origin.y - box.height) * CGFloat(H)
        let w0 = box.width * CGFloat(W)
        let h0 = box.height * CGFloat(H)
        let cx = x0 + w0/2, cy = y0 + h0/2
        let side = max(w0, h0) * 1.25
        var crop = CGRect(x: cx - side/2, y: cy - side/2, width: side, height: side)
        crop = crop.intersection(CGRect(x: 0, y: 0, width: W, height: H))
        guard crop.width > 4, crop.height > 4 else { return nil }

        let ci = CIImage(cvPixelBuffer: buf)
        var img = ci.cropped(to: crop)
        let target = CGFloat(size)
        img = img.transformed(by: CGAffineTransform(scaleX: target/img.extent.width, y: target/img.extent.height))

        let ctx = CIContext(options: [.workingColorSpace: NSNull(), .cacheIntermediates: false])
        var rgba = [UInt8](repeating: 0, count: size*size*4)
        ctx.render(img, toBitmap: &rgba, rowBytes: size*4,
                   bounds: CGRect(x: 0, y: 0, width: target, height: target),
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

        // 1) Quality — input [1,3,112,112], Output "scores" (Regressor, Scalar)
        if let m = qualityModel, let arr = makeArray(buf: buf, box: box, size: qualitySize, batched: true, rgbOrder: [2,1,0]) {
            do {
                let out = try m.prediction(from: MLDictionaryFeatureProvider(dictionary: ["input": MLFeatureValue(multiArray: arr)]))
                if let scores = out.featureValue(for: "scores")?.multiArrayValue {
                    let p = scores.dataPointer.bindMemory(to: Float.self, capacity: scores.count)
                    r.qualityScore = p[0]
                    if scores.count > 1 {
                        var m: Float = 0; for i in 0..<scores.count { m += p[i] }
                        r.qualityScore = m / Float(scores.count)
                    }
                } else { r.errors.append("quality: kein 'scores' Output") }
            } catch { r.errors.append("quality: \(error.localizedDescription)") }
        } else if qualityModel == nil { r.errors.append("quality-Modell fehlt") }

        // 2) Attributes — input [1,3,160,160], Output "output_conf" [1,4]
        if let m = attributeModel, let arr = makeArray(buf: buf, box: box, size: attributeSize, batched: true, rgbOrder: [0,1,2]) {
            do {
                let out = try m.prediction(from: MLDictionaryFeatureProvider(dictionary: ["input": MLFeatureValue(multiArray: arr)]))
                if let conf = out.featureValue(for: "output_conf")?.multiArrayValue {
                    let p = conf.dataPointer.bindMemory(to: Float.self, capacity: conf.count)
                    r.attributeConf = (0..<conf.count).map { p[$0] }
                    r.attrLabel = r.attributeConf.enumerated().max(by: { $0.element < $1.element })?.offset ?? -1
                } else { r.errors.append("attr: kein 'output_conf'") }
            } catch { r.errors.append("attr: \(error.localizedDescription)") }
        } else if attributeModel == nil { r.errors.append("attr-Modell fehlt") }

        // 3) Occlusion — input [3,224,224] (OHNE Batch), Output "output" [1,1,2,224,224]
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
