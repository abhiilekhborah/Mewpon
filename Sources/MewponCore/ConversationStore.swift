import Foundation

public actor ConversationStore {
    private let directory: URL
    public init(directory: URL) { self.directory = directory }
    private var file: URL { directory.appendingPathComponent("conversation.json") }
    private func prepare() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    public func load() throws -> Conversation {
        guard FileManager.default.fileExists(atPath: file.path) else { return Conversation() }
        let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size <= 2_000_000 else { throw MewponError.invalid("Saved history is too large. Clear it in Settings.") }
        return try JSONDecoder().decode(Conversation.self, from: Data(contentsOf: file))
    }
    public func save(_ conversation: Conversation) throws {
        try prepare()
        try JSONEncoder().encode(conversation).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    public func clear() throws {
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }
    public func log(tool: String, success: Bool) throws {
        try prepare()
        let url = directory.appendingPathComponent("actions.log")
        // No prompts, arguments, paths, or raw error text. Bounded local audit log.
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        if size > 256_000 { try Data().write(to: url) }
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
        try handle.seekToEnd()
        // Tool names come from the router registry or a sanitized rejection marker.
        let safeName = tool.filter { $0.isASCII && ($0.isLetter || $0 == "_") }.prefix(40)
        try handle.write(contentsOf: Data("\(ISO8601DateFormatter().string(from: Date())) \(safeName) \(success ? "success" : "failure")\n".utf8))
    }
}
