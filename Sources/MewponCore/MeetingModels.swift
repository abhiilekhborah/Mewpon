import Foundation

public struct MeetingNote:Codable,Identifiable,Equatable,Sendable {
    public var id=UUID()
    public var timestamp:Double
    public var text:String
    public var kind:String
    public var completed:Bool?
    public init(timestamp:Double,text:String,kind:String){self.timestamp=timestamp;self.text=text;self.kind=kind;self.completed=false}
}
public struct GroundedExcerpt:Codable,Identifiable,Equatable,Sendable {
    public var id:UUID {segmentID}
    public var segmentID:UUID
    public var category:String
    public var quote:String
    public var owner:String?
    public var deadline:String?
    public init(segmentID:UUID,category:String,quote:String,owner:String?=nil,deadline:String?=nil){self.segmentID=segmentID;self.category=category;self.quote=quote;self.owner=owner;self.deadline=deadline}
    public func validated(against segments:[TranscriptSegment])->Bool {
        guard ["summary","discussion","decision","action","question"].contains(category),let segment=segments.first(where:{$0.id==segmentID}),!quote.isEmpty,segment.text.contains(quote) else{return false}
        return [owner,deadline].compactMap{$0}.allSatisfy { value in
            guard !value.isEmpty else{return false}
            let pattern="(?<![\\p{L}\\p{N}_])"+NSRegularExpression.escapedPattern(for:value)+"(?![\\p{L}\\p{N}_])"
            return quote.range(of:pattern,options:[.regularExpression,.caseInsensitive,.diacriticInsensitive]) != nil
        }
    }
}
public struct MeetingSlide:Codable,Identifiable,Equatable,Sendable {
    public var id:UUID
    public var timestamp:Double
    public init(id:UUID,timestamp:Double){self.id=id;self.timestamp=timestamp}
}
public struct MeetingDocument:Codable,Identifiable,Equatable,Sendable {
    public var id=UUID()
    public var date=Date()
    public var title:String
    public var source:String
    public var segments:[TranscriptSegment]=[]
    public var notes:[MeetingNote]=[]
    public var excerpts:[GroundedExcerpt]=[]
    public var audioFiles:[UUID]=[]
    public var slides:[MeetingSlide]?
    public var speakerTurns:[SpeakerTurn]?
    public var originalAudioSHA256:String?
    public init(title:String,source:String){self.title=title;self.source=source}
    public var markdown:String {
        "# \(title)\n\nSource: \(source)\n\n## Grounded excerpts\n\n"+excerpts.map{"- **\($0.category.capitalized)**: \($0.quote)"}.joined(separator:"\n")+"\n\n## Notes\n\n"+notes.map{"- [\(TranscriptExport.timestamp($0.timestamp))] **\($0.kind)**: \($0.text)"}.joined(separator:"\n")+"\n\n## Transcript\n\n"+TranscriptExport.text(segments)
    }
}
