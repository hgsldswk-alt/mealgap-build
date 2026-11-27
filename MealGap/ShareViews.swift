import SwiftUI
import UIKit

struct ActivitySheet: UIViewControllerRepresentable {
    let request: ShareRequest
    let completion: (Bool) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: request.items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, success, _, error in
            ShareRequest.cleanup(request.files)
            Task { @MainActor in completion(success && error == nil) }
        }
        return controller
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct SharePreview: View {
    @Environment(\.dismiss) private var dismiss
    let model: AppModel
    let minutes: Int?
    let milestone: Bool
    @State private var data: Data?
    @State private var image: UIImage?
    @State private var share: ShareRequest?
    @State private var requested = false
    @State private var notice: String?
    @State private var preparing = false

    private var title: String { milestone ? "share.milestone" : minutes == nil ? "settings.recommend" : "share.template" }
    private var caption: String {
        L.t(milestone ? "share.milestoneCaption" : minutes == nil ? "share.recommendLine" : "share.templateCaption")
            + "\n" + L.t("share.tags")
    }
    private var shareText: String { minutes.map { "\(caption)\n\(TemplateCode.encode($0))" } ?? caption }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if let image {
                    Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: 390)
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .accessibilityLabel(L.t(title)).accessibilityIdentifier("share.card")
                } else if notice == nil { ProgressView() }
                Text(L.t("share.privacy")).font(.footnote).foregroundStyle(Design.muted)
                MealButton(key: "share.image", id: "share.image", primary: true) { send(template: false) }.disabled(data == nil || preparing)
                if minutes != nil {
                    MealButton(key: "share.copy", id: "share.copy") {
                        if !Launch.testing { UIPasteboard.general.string = shareText }
                        notice = L.t("share.copied")
                    }
                    MealButton(key: "share.file", id: "share.file") { send(template: true) }.disabled(preparing)
                }
                if requested { Text(L.t("share.requested")).accessibilityIdentifier("share.requested") }
                if let notice { Text(notice).font(.subheadline).accessibilityIdentifier("share.notice") }
            }.padding(20).frame(maxWidth: .infinity)
        }
        .background(Design.paper.ignoresSafeArea())
        .navigationTitle(L.t(title))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L.t("common.close")) { dismiss() }.accessibilityIdentifier("share.close") } }
        .task {
            do {
                let (payload, preview) = try await Task.detached { [minutes, milestone] in
                    let payload = try ShareArt.card(minutes: minutes, milestone: milestone)
                    guard let preview = UIImage(data: payload)?.preparingForDisplay() else { throw MealError.storage }
                    return (payload, preview)
                }.value
                data = payload
                image = preview
            } catch { notice = message(error) }
        }
        .sheet(item: $share) { item in
            ActivitySheet(request: item) { success in model.recordShare(success); share = nil }
        }
    }

    private func send(template: Bool) {
        guard let bytes = template ? minutes.map(TemplateCode.data) : data else { return }
        preparing = true
        requested = false
        let filename = template ? "MealGap.mealinterval" : "MealGap-card.png"
        Task {
            defer { preparing = false }
            do {
                let file = try await Task.detached { try ShareRequest.file(bytes, named: filename) }.value
                if Launch.testing { requested = true; ShareRequest.cleanup([file]) }
                else { share = ShareRequest(items: [file, shareText], files: [file]) }
            } catch { notice = message(error) }
        }
    }
}
