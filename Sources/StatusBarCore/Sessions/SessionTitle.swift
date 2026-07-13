import Foundation

/// Resolves a session's display title from its Claude Code transcript.
/// Claude Code appends `{"type":"ai-title","aiTitle":"…"}` records as the
/// session gets (re)named — the last one is current. Transcripts grow to
/// many MB, so only the tail is read.
public enum SessionTitle {
    public static func read(transcript: URL, tailBytes: Int = 262_144) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: transcript) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let offset = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.readToEnd(), !data.isEmpty else { return nil }

        // Split on raw newline bytes — the tail cut can land mid-character,
        // so the bytes must never round-trip through String as a whole.
        var lines = data.split(separator: UInt8(ascii: "\n"))
        if offset > 0, !lines.isEmpty { lines.removeFirst() }  // partial first line

        let marker = Data(#""ai-title""#.utf8)
        var title: String?
        for line in lines where line.range(of: marker) != nil {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  obj["type"] as? String == "ai-title",
                  let t = obj["aiTitle"] as? String, !t.isEmpty else { continue }
            title = t
        }
        return title
    }
}
