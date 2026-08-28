import NotebookKit
import PDFKit
import SwiftUI

/// The passage a citation names, in its original.
///
/// The whole reason a notebook keeps the file it was given: a citation that
/// opens the PDF at page 2517 can be checked, and a citation that quotes a
/// fragment has to be believed. Every answer this app produces is only as good
/// as somebody's ability to disagree with it.
struct SourceViewer: View {
    let citation: NotebookPackage.Turn.Citation
    let package: NotebookPackage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 720, minHeight: 560)
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(citation.citation).font(.headline).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let url = originalURL {
                Button("Open in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .padding(14)
    }

    private var subtitle: String {
        var parts = [String(format: "score %.3f", citation.score)]
        if let page { parts.append("page \(page)") }
        parts.append(fileName)
        return parts.joined(separator: "  ·  ")
    }

    @ViewBuilder private var content: some View {
        if let url = originalURL, url.pathExtension.lowercased() == "pdf" {
            // Opened at the cited page rather than at page one. Landing on the
            // first page of an 8,894 page document is the same as not opening
            // it.
            PDFPage(url: url, page: page ?? 1)
        } else if let text = storedText {
            ScrollView {
                Text(text)
                    .font(.system(.body, design: .default))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
            }
        } else {
            // Said rather than shown blank. A source removed from the package
            // after a turn was recorded is an ordinary thing to happen and the
            // record is still true about what was retrieved at the time.
            ContentUnavailableView(
                "The original is not in this notebook",
                systemImage: "doc.questionmark",
                description: Text("The turn recorded it as \(fileName). It may "
                                  + "have been removed since."))
        }
    }

    /// `originals/file.pdf#page=2517` split back into its parts.
    private var fileName: String {
        String(citation.url.split(separator: "#").first ?? "")
            .split(separator: "/").last.map(String.init) ?? citation.url
    }

    private var page: Int? {
        guard let fragment = citation.url.split(separator: "#").last,
              fragment.hasPrefix("page=") else { return nil }
        return Int(fragment.dropFirst("page=".count))
    }

    private var originalURL: URL? {
        let url = package.originalsURL.appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The chunk as it was stored, for sources with no page to open.
    private var storedText: String? {
        guard FileManager.default.fileExists(atPath: package.indexURL.path),
              let store = try? VectorStore(path: package.indexURL, create: false)
        else { return nil }
        return try? blocking { try await store.text(forCitation: citation.citation,
                                                    url: citation.url) }
    }

    private func blocking<T: Sendable>(
        _ work: @escaping @Sendable () async throws -> T) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: Result<T, Error>?
        Task.detached {
            do { result = .success(try await work()) }
            catch { result = .failure(error) }
            semaphore.signal()
        }
        semaphore.wait()
        return try result!.get()
    }
}

/// A PDF, opened at a page.
struct PDFPage: NSViewRepresentable {
    let url: URL
    let page: Int

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.document = PDFDocument(url: url)
        go(view)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) { go(view) }

    private func go(_ view: PDFView) {
        // 1 based on screen, 0 based in PDFKit.
        guard let document = view.document,
              page >= 1, page <= document.pageCount,
              let target = document.page(at: page - 1) else { return }
        view.go(to: target)
    }
}
