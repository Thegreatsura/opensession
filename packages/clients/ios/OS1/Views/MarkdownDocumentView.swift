import SwiftUI

/// A Markdown file opened on its own, read as a page rather than a chat
/// message: a centred reading column on its own surface, the document type
/// ramp (`MarkdownRenderConfig.os1Document`), and extra air above headings.
///
/// Everything else is `MarkdownBody`, so tables, fenced blocks, task lists and
/// images behave exactly as they do in the transcript. Transcript Markdown
/// never comes through here.
struct MarkdownDocumentView: View {
    private let sections: [MarkdownDocumentSections.Section]

    init(_ text: String) {
        sections = MarkdownDocumentSections.split(text)
    }

    /// The web's 680px column; on a phone the screen is narrower anyway.
    static let readingWidth: CGFloat = 680

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(Array(sections.enumerated()), id: \.offset) { index, section in
                    MarkdownBody(section.text)
                        .padding(.top, MarkdownDocumentSections.gap(
                            before: section,
                            after: index > 0 ? sections[index - 1] : nil
                        ))
                }
            }
            .environment(\.markdownPresentation, .document)
            .frame(maxWidth: Self.readingWidth, alignment: .leading)
            .padding(.horizontal, 22)
            .padding(.top, 28)
            .padding(.bottom, 48)
            .frame(maxWidth: .infinity)
        }
        .background(OS1VisualStyle.documentPage.ignoresSafeArea())
    }
}
