import Cocoa
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Window Controller

final class HistoryWindowController: NSWindowController {

    static let shared = HistoryWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Dictation History — Last 30 Days"
        window.minSize = NSSize(width: 600, height: 500)
        window.isReleasedWhenClosed = false
        window.center()
        window.contentView = NSHostingView(rootView: HistoryView())
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - SwiftUI View

struct HistoryView: View {
    @ObservedObject private var history = HistoryManager.shared
    @State private var searchText: String = ""
    @State private var languageFilter: String = "All"
    @State private var showClearConfirm: Bool = false
    @State private var pendingDelete: DictationEntry? = nil
    @State private var copiedID: UUID? = nil

    private let languages: [String] = ["All", "EN", "BN", "BL"]

    private var filteredEntries: [DictationEntry] {
        history.search(query: searchText, language: languageFilter)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("Search…", text: $searchText)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.secondary.opacity(0.12))
                .cornerRadius(6)
                .frame(maxWidth: 260)

                Picker("", selection: $languageFilter) {
                    ForEach(languages, id: \.self) { lang in
                        Text(lang).tag(lang)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 80)

                Spacer()

                Button(action: exportAsTxt) {
                    Label("Export .txt", systemImage: "square.and.arrow.up")
                }
                .disabled(filteredEntries.isEmpty)

                Button(role: .destructive, action: { showClearConfirm = true }) {
                    Label("Clear All", systemImage: "trash")
                }
                .disabled(history.entries.isEmpty)
            }
            .padding(12)
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            // List
            if filteredEntries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary)
                    Text(history.entries.isEmpty ? "No dictations yet." : "No matches.")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(filteredEntries) { entry in
                            entryRow(entry)
                        }
                    }
                    .padding(12)
                }
            }

            Divider()

            // Footer count
            HStack {
                Text("\(filteredEntries.count) of \(history.entries.count) dictation\(history.entries.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text("Stored at ~/Library/Application Support/YapTextMac/history.json")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .alert("Clear all history?", isPresented: $showClearConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Clear All", role: .destructive) {
                history.clearAll()
            }
        } message: {
            Text("This will permanently delete all \(history.entries.count) saved dictations. This cannot be undone.")
        }
        .alert("Delete this dictation?", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) { pendingDelete = nil }
            Button("Delete", role: .destructive) {
                if let entry = pendingDelete {
                    history.delete(id: entry.id)
                }
                pendingDelete = nil
            }
        } message: {
            Text("This dictation will be permanently removed.")
        }
    }

    // MARK: - Row

    private func entryRow(_ entry: DictationEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(HistoryManager.formatExact(entry.timestamp))
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundColor(.primary)

                languageBadge(entry.language)

                Spacer()

                if copiedID == entry.id {
                    Text("Copied!")
                        .font(.caption)
                        .foregroundColor(.green)
                        .transition(.opacity)
                }

                Button {
                    copy(entry)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy text")

                Button {
                    pendingDelete = entry
                } label: {
                    Image(systemName: "trash")
                        .foregroundColor(.red)
                }
                .buttonStyle(.borderless)
                .help("Delete")
            }

            Text(entry.text)
                .font(.system(.body))
                .foregroundColor(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06))
        .cornerRadius(8)
    }

    private func languageBadge(_ lang: String) -> some View {
        Text(lang)
            .font(.caption2.weight(.bold))
            .foregroundColor(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(badgeColor(lang))
            .cornerRadius(4)
    }

    private func badgeColor(_ lang: String) -> Color {
        switch lang {
        case "EN": return .blue
        case "BN": return .purple
        case "BL": return .orange
        default:   return .gray
        }
    }

    // MARK: - Actions

    private func copy(_ entry: DictationEntry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.text, forType: .string)
        withAnimation { copiedID = entry.id }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            if copiedID == entry.id {
                withAnimation { copiedID = nil }
            }
        }
    }

    private func exportAsTxt() {
        let panel = NSSavePanel()
        panel.title = "Export Dictation History"
        if #available(macOS 11.0, *) {
            panel.allowedContentTypes = [UTType.plainText]
        }
        let timestamp = DateFormatter()
        timestamp.dateFormat = "yyyy-MM-dd"
        panel.nameFieldStringValue = "yaptext-history-\(timestamp.string(from: Date())).txt"

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let text = HistoryManager.shared.exportAsText(entries: filteredEntries)
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
