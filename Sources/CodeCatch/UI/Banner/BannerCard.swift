import SwiftUI

struct BannerCard: View {
    let id: UUID
    @ObservedObject private var model = AppModel.shared

    var body: some View {
        if let item = model.items.first(where: { $0.id == id }) {
            CodeCard(item: item, style: .banner)
                .frame(width: 356)
                .modifier(GlassBackground(shape: RoundedRectangle(cornerRadius: 24, style: .continuous), shadowRadius: 14, shadowY: 6))
                .padding(12)  // room for the glass edge and shadow inside the borderless panel
        }
    }
}
