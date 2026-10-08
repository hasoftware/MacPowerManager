import Foundation

/// Chia ghi chú phát hành (Markdown của CHANGELOG) thành các khối đơn giản để app tự vẽ: tiêu đề `###`, gạch đầu
/// dòng `-`, danh sách số, trích dẫn `>` và đoạn văn. Chữ trong mỗi khối vẫn là Markdown nội dòng (`**đậm**`,
/// `` `mã` ``, liên kết) để app hiển thị bằng `AttributedString(markdown:)`.
public enum ReleaseNoteBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    /// `depth` 0 là cấp ngoài cùng; mỗi 2 dấu cách thụt vào thêm một cấp.
    case bullet(depth: Int, text: String)
    case numbered(number: Int, text: String)
    case quote(String)
    case paragraph(String)

    public static func parse(_ markdown: String) -> [ReleaseNoteBlock] {
        var blocks: [ReleaseNoteBlock] = []
        /// Khối cuối còn nhận dòng nối tiếp (dòng trống kết thúc khối).
        var open = false

        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        for raw in lines {
            let indent = raw.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                open = false
                continue
            }
            if let heading = Self.heading(line) {
                blocks.append(heading)
                open = false
            } else if let text = Self.bulletText(line) {
                blocks.append(.bullet(depth: min(indent / 2, 3), text: text))
                open = true
            } else if let (number, text) = Self.numbered(line) {
                blocks.append(.numbered(number: number, text: text))
                open = true
            } else if line.hasPrefix(">") {
                let text = line.dropFirst().trimmingCharacters(in: .whitespaces)
                if open, case .quote(let previous) = blocks.last {
                    blocks[blocks.count - 1] = .quote(Self.join(previous, text))
                } else {
                    blocks.append(.quote(text))
                }
                open = true
            } else if open, let last = blocks.last {
                // Dòng nối tiếp (Markdown "soft break"): ghép vào khối trước bằng một dấu cách.
                blocks[blocks.count - 1] = last.appending(line)
            } else {
                blocks.append(.paragraph(line))
                open = true
            }
        }
        return blocks
    }

    private func appending(_ line: String) -> ReleaseNoteBlock {
        switch self {
        case .heading: self
        case .bullet(let depth, let text): .bullet(depth: depth, text: Self.join(text, line))
        case .numbered(let number, let text): .numbered(number: number, text: Self.join(text, line))
        case .quote(let text): .quote(Self.join(text, line))
        case .paragraph(let text): .paragraph(Self.join(text, line))
        }
    }

    private static func join(_ a: String, _ b: String) -> String {
        a.isEmpty ? b : a + " " + b
    }

    private static func heading(_ line: String) -> ReleaseNoteBlock? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = line.dropFirst(hashes)
        guard rest.first == " " else { return nil }
        return .heading(level: hashes, text: rest.trimmingCharacters(in: .whitespaces))
    }

    private static func bulletText(_ line: String) -> String? {
        guard let marker = line.first, "-*+".contains(marker), line.dropFirst().first == " " else { return nil }
        return line.dropFirst(2).trimmingCharacters(in: .whitespaces)
    }

    private static func numbered(_ line: String) -> (Int, String)? {
        let digits = line.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, let number = Int(digits) else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return (number, rest.dropFirst(2).trimmingCharacters(in: .whitespaces))
    }
}
