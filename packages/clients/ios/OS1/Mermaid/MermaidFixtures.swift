#if DEBUG
import Foundation

/// Diagrams the repair tests and the screenshot hook share. The first two are
/// the ER diagrams mermaid refuses as written (an attribute named like a key
/// marker, and a generic type); the rest already parse and must come through
/// untouched.
enum MermaidFixtures {
    static let keyNamedAttributes = """
    erDiagram
      ITEM {
        string pk "ORG#orgID"
        string sk
        string Uk PK
      }
    """

    static let genericType = """
    erDiagram
      PLAYLIST ||--o{ TRACK : holds
      PLAYLIST {
        Vec<Track> tracks
        string fk FK
      }
    """

    static let validER = """
    erDiagram
      ACME_ORG ||--o{ MEMBER : "pk to fk"
      MEMBER {
        int id PK
        string[] tags
        string `fk`
      }
    """

    static let sequence = """
    sequenceDiagram
      Alice->>Bob: pk
      Bob-->>Alice: fk
    """

    /// One assistant message carrying all four, for `OS1_SHOW_MERMAID_FIXTURE`.
    static var transcriptMarkdown: String {
        [
            ("Sequence diagram:", sequence),
            ("Valid ER diagram:", validER),
            ("Attribute named like a key marker:", keyNamedAttributes),
            ("Generic attribute type:", genericType),
        ]
        .map { "\($0.0)\n\n```mermaid\n\($0.1)\n```" }
        .joined(separator: "\n\n")
    }
}
#endif
