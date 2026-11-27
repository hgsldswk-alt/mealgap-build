import UIKit

enum ShareArt {
    static let width = 1080
    static let height = 1350
    private static let paper = UIColor(red: 248/255, green: 245/255, blue: 239/255, alpha: 1)
    private static let ink = UIColor(red: 38/255, green: 30/255, blue: 26/255, alpha: 1)
    private static let accent = UIColor(red: 139/255, green: 73/255, blue: 54/255, alpha: 1)

    static func card(minutes: Int?, milestone: Bool, url: String = TemplateCode.downloadURL) throws -> Data {
        guard let qr = TemplateCode.qr(url) else { throw MealError.storage }
        return png(CGSize(width: width, height: height)) { context in
            UIColor.white.setFill()
            UIBezierPath(roundedRect: CGRect(x: 62, y: 60, width: 956, height: 1230), cornerRadius: 38).fill()
            draw(L.t(milestone ? "share.milestone" : minutes == nil ? "app.title" : "share.card"), size: 55, bold: true, color: accent, x: 110, y: 131, width: 850)
            accent.setFill()
            context.fill(CGRect(x: 110, y: 244, width: 98, height: 8))
            let duration = minutes.map { L.duration(Double($0) * 60) }
            let headline = milestone ? L.t("share.milestoneLine") : duration ?? L.t("share.recommendLine")
            draw(headline, size: milestone || duration == nil ? 93 : 126, bold: true, x: 110, y: 325, width: 850, height: 370)
            if let duration {
                draw(milestone ? L.f("home.target", duration) : L.t("share.purpose"), size: 44, x: 110, y: 703, width: 840)
            }
            draw(L.t("share.tags"), size: 36, color: accent, x: 110, y: 893, width: 535)
            draw(L.t("app.title"), size: 49, bold: true, x: 110, y: 1010, width: 520)
            draw(L.t(url == TemplateCode.pendingURL ? "share.pendingQR" : "share.download"), size: 33, x: 110, y: 1143, width: 500)
            context.interpolationQuality = .none
            UIImage(cgImage: qr).draw(in: CGRect(x: 708, y: 930, width: 240, height: 240))
        }
    }

    static func history(_ records: [IntervalRecord]) throws -> [URL] {
        let pageSize = 24
        var urls: [URL] = []
        do {
            for start in stride(from: 0, to: max(records.count, 1), by: pageSize) {
                let page = records.dropFirst(start).prefix(pageSize)
                let data = png(CGSize(width: 1080, height: 340 + 202 * max(page.count, 1))) { context in
                    draw(L.t("history.title"), size: 73, bold: true, x: 78, y: 76, width: 924)
                    if page.isEmpty { draw(L.t("history.empty"), size: 44, x: 78, y: 248, width: 924) }
                    for (index, record) in page.enumerated() {
                        let top = CGFloat(250 + index * 202)
                        accent.setFill()
                        context.fill(CGRect(x: 78, y: top, width: 924, height: 2))
                        draw(L.duration(record.duration), size: 46, bold: true, color: accent, x: 78, y: top + 16, width: 924)
                        draw(record.range, size: 33, x: 78, y: top + 83, width: 924, height: 112)
                    }
                }
                urls.append(try ShareRequest.file(data, named: "MealGap-\(urls.count + 1).png"))
            }
            return urls
        } catch {
            ShareRequest.cleanup(urls)
            throw error
        }
    }

    private static func png(_ size: CGSize, draw: (CGContext) -> Void) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).pngData { renderer in
            paper.setFill()
            renderer.fill(CGRect(origin: .zero, size: size))
            draw(renderer.cgContext)
        }
    }

    private static func draw(_ text: String, size: CGFloat, bold: Bool = false, color: UIColor = ink,
                             x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat = 165) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let settings: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular),
            .foregroundColor: color, .paragraphStyle: paragraph
        ]
        (text as NSString).draw(with: CGRect(x: x, y: y, width: width, height: height), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: settings, context: nil)
    }
}

struct ShareRequest: Identifiable {
    let id = UUID()
    let items: [Any]
    let files: [URL]

    static func file(_ data: Data, named name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "MealGap-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: name)
        do { try data.write(to: url, options: [.atomic, .completeFileProtection]) }
        catch { try? FileManager.default.removeItem(at: directory); throw error }
        return url
    }

    static func cleanup(_ urls: [URL]) {
        for url in urls { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    }
}
