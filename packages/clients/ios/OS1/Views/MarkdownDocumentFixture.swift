import SwiftUI

#if DEBUG && os(iOS)
/// The native screenshot harness's Markdown file fixture
/// (`OS1_MARKDOWN_DOCUMENT_FIXTURE`): a document with every block the file
/// viewer styles, drawn without a server round trip. `tail` starts at the
/// table so the lower blocks fit one screenshot.
struct MarkdownDocumentFixture: View {
    let mode: String

    var body: some View {
        NavigationStack {
            MarkdownDocumentView(mode == "tail" ? Self.tail : Self.head + "\n\n" + Self.tail)
                .navigationTitle("release-notes.md")
                .navigationBarTitleDisplayMode(.inline)
        }
    }

    private static let head = """
    # Release notes

    A short summary of what changed in this build and what still needs work.

    ## Highlights

    - Markdown files open as a page with a reading column.
    - Headings step down clearly from **title** to *section*.
      - Nested items keep a quieter bullet.
    - Tables sit in a hairline frame.

    1. Build both schemes.
    2. Run the unit tests.
    3. Capture screenshots.

    ### Checklist

    - [x] Port the document layout
    - [x] Keep chat Markdown unchanged
    - [ ] Ship to TestFlight
    """

    private static let tail = """
    ## Numbers

    | Surface | Before | After |
    | --- | ---: | ---: |
    | Body line | 26 pt | 27 pt |
    | Block gap | 8 pt | 16 pt |
    | Section gap | 8 pt | 40 pt |

    ## Code

    Run `xcodebuild` from the project folder:

    ```sh
    xcodegen generate
    xcodebuild -scheme OS1 build
    ```

    > Chat Markdown keeps its dense scale. Only files read as pages.

    ## Image

    ![Weekly sessions](/media?path=/tmp/md-doc-fixture/chart.png)

    ---

    #### Notes

    Dynamic Type and dark mode follow the system.
    """
}
#endif
