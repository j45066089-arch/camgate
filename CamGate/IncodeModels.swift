//
//  IncodeModels.swift
//  CamGate — lädt Incodes eigene (aus bunq entschlüsselte) CoreML-Modelle
//
import Foundation
import CoreML
import CoreImage
import CoreVideo
import Vision
import Accelerate

// 5-Punkt-Alignment wie Incode: rEye, lEye, Nase, rMouth, lMouth
// Folge der InsightFace/ArcFace-Konvention.
enum IncodeInference {
    // Ziel-Größen der Modelle
    static let qualitySize = 112
    static let attributeSize = 160
    static let occlusionSize = 224

    struct Result {
        var qualityScore: Float = .nan
        var qualityOK: Bool = false
        var attributeConf: [Float] = []   // [1,4]
        var attrLabel: Int = -1
        var occlusionRatio: Float = .nan // Anteil verdeckter Pixel
        var occlusionOK: Bool = false
        var error: String?
    }

    static let qualityModel: MLModel? = try? load("selfie_quality_model_v1_0_fp16").model
    static let attributeModel: MLModel? = try? load("face_attributes_v1_3_f16").model
    static let occlusionModel: MLModel? = try? load("face_occlusion_v0_2_f16").model

    private static func load(_ name: String) throws -> MLModel {
        guard let url = Bundle.main.url(forResource: name, withExtension: "mlmodelc") else {
            throw NSError(domain: "CamGate", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(name).mlmodelc nicht im Bundle"])
        }
        let compiled = try MLModel(contentsOf: url)
        return compiled
    }

    // ---- CoreML-Input bauen: CVPixelBuffer -> RGBA8 -> crop -> resize -> [1,3,H,W] Float32 ----
    static func mlArray(_ buf: CVPixelBuffer, box: CGRect, size: Int) -> MLMultiArray? {
        // box: normiert 0..1, Vision-Konvention Origin unten-links
        let W = CVPixelBufferGetWidth(buf), H = CVPixelBufferGetHeight(buf)
        // Vision->Top-Left konvertieren
        let pxX = box.origin.x * CGFloat(W)
        let pxY = (1.0 - box.origin.y - box.height) * CGFloat(H)
        let pxW = box.width * CGFloat(W)
        let pxH = box.height * CGFloat(H)

        let ci = CIImage(cvPixelBuffer: buf)
        let cropRect = CGRect(x: pxX, y: pxY, width: pxW, height: pxH)
        // mit Puffer drumherum (10%) gegen Crop-Verlust
        let inset = cropRect.insetBy(dx: -pxW*0.10, dy: -pxH*0.10).intersection(CGRect(x:0,y:0,width:W,height:H))
        guard inset.width > 1, inset.height > 1 else { return nil }

        let cropped = ci.cropped(to: inset)
        // Resize via CIImage transform (Proportional)
        let scale = CGFloat(size) / max(inset.width, inset.height)
        let scaled = cropped.transformed(by: .init(scaleX: scale, y: scale)).transformed(by: .init(translationX: 0, y: 0))
        // quadratisch zentrieren: aus Mitte schneiden
        let centered = scaled.transformed(by: .init(translationX: (scaled.extent.width - CGFloat(size))/2, y: (scaled.extent.height - CGFloat(size))/2))

        // Rendern zu RGBA8
        let ctx = CIContext(options: [.workingColorSpace: NSNull()])
        var px = [UInt8](repeating: 0, count: size*size*4)
        ctx.render(centered,
                   toBitmap: &px, rowBytes: size*4, bounds: CGRect(x: 0, y: 0, width: size, height: size),
                   format: .RGBA8, colorSpace: nil)

        // -> [1,3,size,size] Float32, CHW, RGB
        let arr = try? MLMultiArray(shape: [1, 3, NSNumber(value: size), NSNumber(value: size)], dataType: .float32)
        guard let arr else { return nil }
        let p = arr.dataPointer.bindMemory(to: Float.self, capacity: arr.count)
        var i = 0
        for c in 0..<3 {          // R,G,B
            for y in 0..<size {
                for x in 0..<size {
                    let idx = (y*size + x)*4
                    let byte = px[idx + c]
                    p[i] = Float(byte) / 255.0   // 0..1
                    i += 1
                }
            }
        }
        return arr
    }

    // ---- Inference auf einem Frame mit Face-Box ----
    static func run(_ buf: CVPixelBuffer, box: CGRect) -> Result {
        var r = Result()
        // 1) Quality
        if let qm = qualityModel, let arr = mlArray(buf, box: box, size: qualitySize) {
            let feat = try? MLDictionaryFeatureProvider(dictionary: ["input": MLFeatureValue(multiArray: arr)])
            if let out = try? qm.prediction(from: feat!) {
                // Output "scores": MultiArray [1, 6272]? -> Mittelwert als Quality-Score
                if let scores = out.featureValue(for: "scores")?.multiArrayValue {
                    let p = scores.dataPointer.bindMemory(to: Float.self, capacity: scores.count)
                    var sum: Float = 0
                    for i in 0..<scores.count { sum += p[i] }
                    r.qualityScore = sum / Float(scores.count)
                }
            }
        }
        // 2) Attributes
        if let am = attributeModel, let arr = mlArray(buf, box: box, size: attributeSize) {
            let feat = try? MLDictionaryFeatureProvider(dictionary: ["input": MLFeatureValue(multiArray: arr)])
            if let out = try? am.prediction(from: feat!),
               let conf = out.featureValue(for: "output_conf")?.multiArrayValue {
                let p = conf.dataPointer.bindMemory(to: Float.self, capacity: conf.count)
                r.attributeConf = (0..<conf.count).map { p[$0] }
                r.attrLabel = r.attributeConf.enumerated().max(by: { $0.element < $1.element })?.offset ?? -1
            }
        }
        // 3) Occlusion
        if let om = occlusionModel, let arr = mlArray(buf, box: box, size: occlusionSize) {
            let feat = try? MLDictionaryFeatureProvider(dictionary: ["input": MLFeatureValue(multiArray: arr)])
            if let out = try? om.prediction(from: feat!),
               let mask = out.featureValue(for: "output")?.multiArrayValue {
                // [1,1,2,224,224] -> Kanal 1 = verdeckt-Anteil
                let p = mask.dataPointer.bindMemory(to: Float.self, capacity: mask.count)
                let perChannel = mask.count / 2
                var occ: Float = 0, total: Float = 0
                for i in 0..<perChannel {
                    let a = p[i]          // Kanal 0
                    let b = p[i + perChannel]  // Kanal 1
                    if b > a { occ += 1 }
                    total += 1
                }
                r.occlusionRatio = occ / total
            }
        }
        return r
    }
}
