import Foundation

public struct TranscriptSegment: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var start: Double
    public var end: Double
    public var text: String
    public var speaker: String?
    public var speakerSource:String?
    public init(start: Double, end: Double, text: String, speaker: String? = nil) {
        id=UUID();self.start=max(0,start);self.end=max(start,end);self.text=text;self.speaker=speaker;self.speakerSource=speaker==nil ? nil:"manual"
    }
    public var label: String { guard let speaker else{return "Speaker unknown"};return speakerSource=="automatic" ? speaker+" (automatic)":speaker }
}
public enum TranscriptExport {
    public static func timestamp(_ seconds: Double, srt: Bool = false) -> String {
        let ms=max(0,Int((seconds*1000).rounded()))
        return String(format:srt ? "%02d:%02d:%02d,%03d":"%02d:%02d:%02d.%03d",ms/3600000,(ms/60000)%60,(ms/1000)%60,ms%1000)
    }
    public static func srt(_ segments:[TranscriptSegment])->String {
        segments.enumerated().map { index,s in "\(index+1)\n\(timestamp(s.start,srt:true)) --> \(timestamp(s.end,srt:true))\n\(s.text.replacingOccurrences(of:"-->",with:"→"))\n" }.joined(separator:"\n")
    }
    public static func text(_ segments:[TranscriptSegment])->String { segments.map { "[\(timestamp($0.start))] \($0.label): \($0.text)" }.joined(separator:"\n\n") }
}
public struct VoiceEndpoint: Sendable {
    public private(set) var heardSpeech=false
    public private(set) var silence=0.0
    public private(set) var elapsed=0.0
    private var noise=0.002
    public init() {}
    public mutating func update(rms: Double, duration: Double) -> Bool {
        elapsed += duration
        let active=rms > max(0.008,noise*3)
        if active {heardSpeech=true;silence=0} else {silence += duration;noise=noise*0.98+min(rms,0.008)*0.02}
        return heardSpeech && silence >= 1.0 || elapsed >= 30
    }
    public static func wakeCommand(_ text:String)->String? {
        let normalized=CommandNormalizer.normalize(text)
        for phrase in ["hey mewpon", "hey mew pon", "hey moupon"] {
            if normalized==phrase { return "" }
            if normalized.hasPrefix(phrase+" ") { return String(normalized.dropFirst(phrase.count+1)) }
        }
        return nil
    }
}
public actor InferenceScheduler {
    public static let shared=InferenceScheduler()
    private var active: UUID?
    public func begin(wait:Bool=true) async throws -> UUID {
        if wait {
            let deadline=ContinuousClock.now.advanced(by:.seconds(30))
            while active != nil,ContinuousClock.now<deadline {try await Task.sleep(for:.milliseconds(20))}
            try Task.checkCancellation()
        }
        guard active==nil else { throw MewponError.unavailable("Another local inference job is running. Finish or stop it before starting this one.") }
        let id=UUID();active=id;return id
    }
    public func end(_ id:UUID) {if active==id{active=nil}}
}
