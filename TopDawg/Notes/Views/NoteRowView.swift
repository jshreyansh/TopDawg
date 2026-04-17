import SwiftUI

struct NoteRowView: View {
    let item: NoteItem
    var onDelete: () -> Void

    @State private var isHovered  = false
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                // Kind indicator dot
                Circle()
                    .fill(item.kind == .link ? Color.claudeTeal : Color.claudeCoral)
                    .frame(width: 5, height: 5)
                    .padding(.top, 5)

                VStack(alignment: .leading, spacing: 3) {
                    // Title row
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        Text(item.displayTitle)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundColor(.white.opacity(0.88))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 6)
                        Text(timeAgo(item.createdAt))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.white.opacity(0.22))
                    }

                    // Content area
                    if item.kind == .link {
                        linkArea
                    } else {
                        textPreview
                    }

                    // Source badge
                    if let app = item.sourceApp, app != "TopDawg" {
                        Text(app.lowercased())
                            .font(.system(size: 8, weight: .medium, design: .monospaced))
                            .foregroundColor(.white.opacity(0.18))
                    }
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHovered ? Color.white.opacity(0.07) : Color.clear)
        )
        .overlay(alignment: .topTrailing) {
            if isHovered {
                Button(action: onDelete) {
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundColor(.white.opacity(0.35))
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .padding(5)
                .transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { handleTap() }
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isHovered)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: isExpanded)
    }

    // MARK: - Link area

    @ViewBuilder
    private var linkArea: some View {
        if let preview = item.linkPreview {
            HStack(alignment: .top, spacing: 7) {
                previewThumbnail(preview: preview)

                VStack(alignment: .leading, spacing: 2) {
                    if let t = preview.title {
                        Text(t)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.white.opacity(0.80))
                            .lineLimit(1)
                    }
                    if let d = preview.description {
                        Text(d)
                            .font(.system(size: 9))
                            .foregroundColor(.white.opacity(0.40))
                            .lineLimit(2)
                    }
                    Text(preview.siteName ?? preview.displayHost)
                        .font(.system(size: 8, weight: .semibold, design: .monospaced))
                        .foregroundColor(.claudeTeal.opacity(0.65))
                }
                Spacer(minLength: 0)
            }
            .padding(7)
            .background(Color.white.opacity(0.04))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
            )
            .cornerRadius(6)
        } else {
            HStack(spacing: 5) {
                Text(URL(string: item.content)?.host ?? item.content)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.claudeTeal.opacity(0.55))
                    .lineLimit(1)
                Spacer(minLength: 0)
                ProcessingSpinner(size: 9, color: .white.opacity(0.2))
            }
            .padding(.vertical, 2)
        }
    }

    @ViewBuilder
    private func previewThumbnail(preview: LinkPreview) -> some View {
        if let imgStr = preview.imageURL, let imgURL = URL(string: imgStr) {
            AsyncImage(url: imgURL) { phase in
                switch phase {
                case .success(let image):
                    image.resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 52, height: 36)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                default:
                    faviconBox(preview: preview)
                }
            }
        } else {
            faviconBox(preview: preview)
        }
    }

    @ViewBuilder
    private func faviconBox(preview: LinkPreview) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.05))
            if let favStr = preview.faviconURL, let favURL = URL(string: favStr) {
                AsyncImage(url: favURL) { phase in
                    if case .success(let img) = phase {
                        img.resizable().aspectRatio(contentMode: .fit).frame(width: 16, height: 16)
                    } else {
                        Image(systemName: "globe")
                            .font(.system(size: 12))
                            .foregroundColor(.claudeTeal.opacity(0.35))
                    }
                }
            } else {
                Image(systemName: "globe")
                    .font(.system(size: 12))
                    .foregroundColor(.claudeTeal.opacity(0.35))
            }
        }
        .frame(width: 52, height: 36)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    // MARK: - Text preview

    private var textPreview: some View {
        Text(item.shortPreview)
            .font(.system(size: 9.5))
            .foregroundColor(.white.opacity(0.38))
            .lineLimit(isExpanded ? 10 : 2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Actions

    private func handleTap() {
        if item.kind == .link, let url = item.url {
            NSWorkspace.shared.open(url)
        } else {
            withAnimation { isExpanded.toggle() }
        }
    }

    private func timeAgo(_ date: Date) -> String {
        let s = Int(Date().timeIntervalSince(date))
        if s < 60      { return "now" }
        if s < 3_600   { return "\(s / 60)m" }
        if s < 86_400  { return "\(s / 3_600)h" }
        return "\(s / 86_400)d"
    }
}
