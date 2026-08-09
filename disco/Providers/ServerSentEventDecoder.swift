import Foundation

/// 按 SSE 帧边界收集 `data:` 行；可接受 URLSession 任意粒度的字节分片。
struct ServerSentEventDecoder {
    private var lineBytes: [UInt8] = []
    private var dataLines: [String] = []

    mutating func append(_ byte: UInt8) -> String? {
        guard byte == 0x0A else {
            lineBytes.append(byte)
            return nil
        }

        var line = String(decoding: lineBytes, as: UTF8.self)
        lineBytes.removeAll(keepingCapacity: true)
        if line.last == "\r" {
            line.removeLast()
        }

        if line.isEmpty {
            return flushDataLines()
        }
        guard line.hasPrefix("data:") else { return nil }

        var value = String(line.dropFirst(5))
        if value.first == " " {
            value.removeFirst()
        }
        dataLines.append(value)
        return nil
    }

    mutating func finish() -> String? {
        if !lineBytes.isEmpty {
            _ = append(0x0A)
        }
        return flushDataLines()
    }

    private mutating func flushDataLines() -> String? {
        guard !dataLines.isEmpty else { return nil }
        let payload = dataLines.joined(separator: "\n")
        dataLines.removeAll(keepingCapacity: true)
        return payload
    }
}
