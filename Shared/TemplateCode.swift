import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import UniformTypeIdentifiers

extension UTType {
    static let mealInterval = UTType(exportedAs: "com.hgsldswk.mealgap.template", conformingTo: .json)
}

enum TemplateCode {
    static let limit = 4096
    static let pendingURL = "https://hgsldswk-alt.github.io/mealgap-support/"
    static var downloadURL: String {
        if let id = Bundle.main.object(forInfoDictionaryKey: "APP_STORE_ID") as? String,
           !id.isEmpty, id.utf8.allSatisfy({ (48...57).contains($0) }) {
            return "https://apps.apple.com/app/id\(id)"
        }
        return pendingURL
    }

    static func data(_ minutes: Int) -> Data { Data("{\"version\":1,\"targetMinutes\":\(minutes)}".utf8) }
    static func encode(_ minutes: Int) -> String {
        "MI1:" + data(minutes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ text: String) throws -> Int {
        guard text.utf8.count <= limit,
              let match = text.split(whereSeparator: \.isWhitespace).first(where: { $0.hasPrefix("MI1:") }) else { throw MealError.invalidTemplate }
        let raw = match.dropFirst(4)
        guard !raw.isEmpty, raw.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else { throw MealError.invalidTemplate }
        var base = raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base += String(repeating: "=", count: (4 - base.count % 4) % 4)
        guard let payload = Data(base64Encoded: base) else { throw MealError.invalidTemplate }
        return try decode(payload)
    }

    static func decode(_ bytes: Data) throws -> Int {
        guard bytes.count <= limit, let text = String(data: bytes, encoding: .utf8),
              let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              Set(object.keys) == ["version", "targetMinutes"],
              text.range(of: #"^\s*\{\s*"(?:version|targetMinutes)"\s*:\s*[0-9]+\s*,\s*"(?:version|targetMinutes)"\s*:\s*[0-9]+\s*\}\s*$"#, options: .regularExpression) != nil,
              object["version"] as? Int == 1, let minutes = object["targetMinutes"] as? Int,
              (1...10080).contains(minutes) else { throw MealError.invalidTemplate }
        return minutes
    }

    static func fromFile(_ url: URL) throws -> Int {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        return try decode(file.read(upToCount: limit + 1) ?? Data())
    }

    static func qr(_ url: String, scale: Int = 8) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let image = output.transformed(by: CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale)))
        return CIContext().createCGImage(image, from: image.extent)
    }
}
