import SwiftUI
import UniformTypeIdentifiers

struct NotesTabView: View {
    @ObservedObject var store: NoteStore

    @State private var isDragTargeted = false
    @State private var isAdding       = false
    @State private var inputText      = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            // thin separator
            Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1).padding(.vertical, 5)

            if isAdding {
                inputRow
                    .padding(.bottom, 7)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if store.notes.isEmpty && !isDragTargeted && !isAdding {
                emptyState
            } else if !store.notes.isEmpty || isDragTargeted {
                notesList
            }

            Spacer(minLength: 0)
        }
        .onDrop(of: [.url, .plainText, .text, .fileURL],
                isTargeted: $isDragTargeted,
                perform: handleDrop)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: isDragTargeted)
        .animation(.spring(response: 0.28, dampingFraction: 0.85), value: isAdding)
        .onChange(of: isAdding) { adding in
            if adding {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { inputFocused = true }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 5) {
            // Orange dot — matches claude-island's identity dot
            Circle()
                .fill(Color.claudeCoral)
                .frame(width: 6, height: 6)

            Text("notes")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.85))

            if !store.notes.isEmpty {
                Text("\(store.notes.count)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.white.opacity(0.28))
            }

            Spacer()

            Button(action: {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                    isAdding.toggle()
                    if isAdding { inputText = "" }
                }
            }) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isAdding ? Color.white.opacity(0.08) : Color.white.opacity(0.06))
                    Image(systemName: isAdding ? "xmark" : "plus")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundColor(.white.opacity(isAdding ? 0.35 : 0.5))
                }
                .frame(width: 20, height: 18)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Inline input row (pill-shaped, claude-island style)

    private var inputRow: some View {
        HStack(spacing: 8) {
            TextField("paste text or URL…", text: $inputText)
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: .rounded))
                .foregroundColor(.white.opacity(0.88))
                .focused($inputFocused)
                .onSubmit { saveInput() }

            if !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button(action: saveInput) {
                    Text("save")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundColor(.black)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.claudeCoral))
                }
                .buttonStyle(.plain)
                .transition(.opacity.combined(with: .scale(scale: 0.85)))
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
                )
        )
        .animation(.spring(response: 0.22, dampingFraction: 0.8), value: inputText.isEmpty)
    }

    // MARK: - Notes list

    private var notesList: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 2) {
                if isDragTargeted {
                    dropBanner
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                ForEach(store.notes) { item in
                    NoteRowView(item: item) {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            store.delete(item)
                        }
                    }
                }
            }
        }
        // fade top/bottom edges like claude-island scroll views
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.04),
                    .init(color: .black, location: 0.94),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    // MARK: - Drop banner

    private var dropBanner: some View {
        HStack(spacing: 5) {
            Circle().fill(Color.claudeTeal).frame(width: 5, height: 5)
            Text("drop to save")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(.claudeTeal.opacity(0.85))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.claudeTeal.opacity(0.07))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.claudeTeal.opacity(0.25),
                                style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                )
        )
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 6) {
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(Color.white.opacity(0.10 - Double(i) * 0.025))
                        .frame(width: 5, height: 5)
                }
            }
            Text("no notes yet")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundColor(.white.opacity(0.28))
            Text("tap + or drag text / a URL here")
                .font(.system(size: 9, design: .rounded))
                .foregroundColor(.white.opacity(0.16))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 28)
    }

    // MARK: - Save from input

    private func saveInput() {
        let t = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if let url = URL(string: t), url.scheme == "http" || url.scheme == "https" {
            store.captureLink(url, from: "TopDawg")
        } else {
            store.captureText(t, from: "TopDawg")
        }
        withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
            inputText = ""
            isAdding  = false
        }
    }

    // MARK: - Drop handler

    @discardableResult
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let sourceApp = NSWorkspace.shared.frontmostApplication?.localizedName
        var handled = false

        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                    let url: URL?
                    if let u = item as? URL                       { url = u }
                    else if let d = item as? Data                 { url = URL(dataRepresentation: d, relativeTo: nil) }
                    else if let s = item as? String               { url = URL(string: s) }
                    else                                          { url = nil }

                    if let u = url, u.scheme == "http" || u.scheme == "https" {
                        DispatchQueue.main.async { self.store.captureLink(u, from: sourceApp) }
                    }
                }
                handled = true; continue
            }

            if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
                    let text: String?
                    if let s = item as? String        { text = s }
                    else if let d = item as? Data     { text = String(data: d, encoding: .utf8) }
                    else                              { text = nil }

                    guard let t = text,
                          !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    else { return }

                    let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let u = URL(string: trimmed), u.scheme == "http" || u.scheme == "https" {
                        DispatchQueue.main.async { self.store.captureLink(u, from: sourceApp) }
                    } else {
                        DispatchQueue.main.async { self.store.captureText(trimmed, from: sourceApp) }
                    }
                }
                handled = true; continue
            }
        }
        return handled
    }
}
