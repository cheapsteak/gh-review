import SwiftUI
import MarkdownUI

private extension Color {
    static let mdText = Color(light: Color(red: 0.024, green: 0.024, blue: 0.024),
                              dark: Color(red: 0.984, green: 0.984, blue: 0.988))
    static let mdSecondaryText = Color(light: Color(red: 0.42, green: 0.43, blue: 0.48),
                                       dark: Color(red: 0.57, green: 0.58, blue: 0.63))
    static let mdTertiaryText = Color(light: Color(red: 0.42, green: 0.43, blue: 0.48),
                                      dark: Color(red: 0.43, green: 0.44, blue: 0.49))
    static let mdSecondaryBg = Color(light: Color(red: 0.969, green: 0.969, blue: 0.976),
                                     dark: Color(red: 0.145, green: 0.149, blue: 0.165))
    static let mdLink = Color(light: Color(red: 0.173, green: 0.396, blue: 0.812),
                              dark: Color(red: 0.298, green: 0.557, blue: 0.973))
    static let mdBorder = Color(light: Color(red: 0.894, green: 0.894, blue: 0.910),
                                dark: Color(red: 0.259, green: 0.267, blue: 0.306))
    static let mdDivider = Color(light: Color(red: 0.816, green: 0.816, blue: 0.827),
                                 dark: Color(red: 0.200, green: 0.204, blue: 0.220))
}

extension Theme {
    static let ghReview = Theme()
        .text {
            ForegroundColor(.mdText)
            FontSize(13)
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(.em(0.85))
            BackgroundColor(.mdSecondaryBg)
        }
        .strong {
            FontWeight(.semibold)
        }
        .link {
            ForegroundColor(.mdLink)
        }
        .heading1 { configuration in
            VStack(alignment: .leading, spacing: 0) {
                configuration.label
                    .relativePadding(.bottom, length: .em(0.3))
                    .relativeLineSpacing(.em(0.125))
                    .markdownMargin(top: 24, bottom: 16)
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(.em(2))
                    }
                Divider().overlay(Color.mdDivider)
            }
        }
        .heading2 { configuration in
            VStack(alignment: .leading, spacing: 0) {
                configuration.label
                    .relativePadding(.bottom, length: .em(0.3))
                    .relativeLineSpacing(.em(0.125))
                    .markdownMargin(top: 24, bottom: 16)
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(.em(1.5))
                    }
                Divider().overlay(Color.mdDivider)
            }
        }
        .heading3 { configuration in
            configuration.label
                .relativeLineSpacing(.em(0.125))
                .markdownMargin(top: 24, bottom: 16)
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(1.25))
                }
        }
        .heading4 { configuration in
            configuration.label
                .relativeLineSpacing(.em(0.125))
                .markdownMargin(top: 24, bottom: 16)
                .markdownTextStyle { FontWeight(.semibold) }
        }
        .heading5 { configuration in
            configuration.label
                .relativeLineSpacing(.em(0.125))
                .markdownMargin(top: 24, bottom: 16)
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(0.875))
                }
        }
        .heading6 { configuration in
            configuration.label
                .relativeLineSpacing(.em(0.125))
                .markdownMargin(top: 24, bottom: 16)
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(0.85))
                    ForegroundColor(.mdTertiaryText)
                }
        }
        .paragraph { configuration in
            configuration.label
                .fixedSize(horizontal: false, vertical: true)
                .relativeLineSpacing(.em(0.25))
                .markdownMargin(top: 0, bottom: 16)
        }
        .blockquote { configuration in
            HStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.mdBorder)
                    .relativeFrame(width: .em(0.2))
                configuration.label
                    .markdownTextStyle { ForegroundColor(.mdSecondaryText) }
                    .relativePadding(.horizontal, length: .em(1))
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .codeBlock { configuration in
            ScrollView(.horizontal) {
                configuration.label
                    .fixedSize(horizontal: false, vertical: true)
                    .relativeLineSpacing(.em(0.225))
                    .markdownTextStyle {
                        FontFamilyVariant(.monospaced)
                        FontSize(.em(0.85))
                    }
                    .padding(16)
            }
            .background(Color.mdSecondaryBg)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .markdownMargin(top: 0, bottom: 16)
        }
        .listItem { configuration in
            configuration.label
                .markdownMargin(top: .em(0.25))
        }
        .taskListMarker { configuration in
            Image(systemName: configuration.isCompleted ? "checkmark.square.fill" : "square")
                .symbolRenderingMode(.hierarchical)
                .imageScale(.small)
                .relativeFrame(minWidth: .em(1.5), alignment: .trailing)
        }
        .table { configuration in
            configuration.label
                .fixedSize(horizontal: false, vertical: true)
                .markdownTableBorderStyle(.init(color: .mdBorder))
                .markdownTableBackgroundStyle(
                    .alternatingRows(Color.clear, Color.mdSecondaryBg)
                )
                .markdownMargin(top: 0, bottom: 16)
        }
        .tableCell { configuration in
            configuration.label
                .markdownTextStyle {
                    if configuration.row == 0 {
                        FontWeight(.semibold)
                    }
                    BackgroundColor(nil)
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 6)
                .padding(.horizontal, 13)
                .relativeLineSpacing(.em(0.25))
        }
        .thematicBreak {
            Divider()
                .relativeFrame(height: .em(0.25))
                .overlay(Color.mdBorder)
                .markdownMargin(top: 24, bottom: 24)
        }
}

struct MarkdownWebView: View {
    let markdown: String

    var body: some View {
        let segments = Self.parseDetailsBlocks(markdown)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .markdown(let text):
                    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Markdown(text)
                            .markdownTheme(.ghReview)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                case .details(let summary, let content):
                    DisclosureGroup {
                        MarkdownWebView(markdown: content)
                            .padding(.top, 4)
                    } label: {
                        Text(summary)
                            .font(.subheadline)
                            .fontWeight(.medium)
                    }
                    .padding(8)
                    .background(Color.mdSecondaryBg)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }

    enum Segment {
        case markdown(String)
        case details(summary: String, content: String)
    }

    static func parseDetailsBlocks(_ input: String) -> [Segment] {
        var segments: [Segment] = []
        let remaining = input

        // Pattern: <details> ... <summary>...</summary> ... </details>
        // Handles optional whitespace/newlines between tags
        let pattern = "(?s)<details[^>]*>\\s*<summary[^>]*>(.*?)</summary>(.*?)</details>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return [.markdown(input)]
        }

        var lastEnd = remaining.startIndex

        let nsRange = NSRange(remaining.startIndex..., in: remaining)
        let matches = regex.matches(in: remaining, range: nsRange)

        if matches.isEmpty {
            return [.markdown(input)]
        }

        for match in matches {
            guard let summaryRange = Range(match.range(at: 1), in: remaining),
                  let contentRange = Range(match.range(at: 2), in: remaining),
                  let fullRange = Range(match.range, in: remaining) else { continue }

            // Text before this <details> block
            let before = String(remaining[lastEnd..<fullRange.lowerBound])
            if !before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                segments.append(.markdown(before))
            }

            let summary = String(remaining[summaryRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            let content = String(remaining[contentRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            segments.append(.details(summary: summary, content: content))

            lastEnd = fullRange.upperBound
        }

        // Text after last </details>
        let after = String(remaining[lastEnd...])
        if !after.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            segments.append(.markdown(after))
        }

        return segments
    }
}
