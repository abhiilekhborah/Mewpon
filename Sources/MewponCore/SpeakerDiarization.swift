import Foundation

public struct SpeakerTurn:Codable,Equatable,Sendable {
    public var start:Double
    public var end:Double
    public var speaker:Int
    /// A clustering similarity score, not a calibrated probability; -2 means unavailable.
    public var confidence:Double
    public init(start:Double,end:Double,speaker:Int,confidence:Double){self.start=start;self.end=end;self.speaker=speaker;self.confidence=confidence}
    public var valid:Bool{start.isFinite && end.isFinite && start>=0 && end>start && end<=7201 && (0..<1000).contains(speaker) && confidence.isFinite && (confidence == -2 || (-1...1).contains(confidence))}
}
public enum SpeakerAlignment {
    public static func apply(_ turns:[SpeakerTurn],to segments:[TranscriptSegment])->[TranscriptSegment] {
        segments.map { original in
            guard original.speakerSource != "manual",!(original.speaker != nil && original.speakerSource==nil) else{return original}
            var segment=original;segment.speaker=nil;segment.speakerSource=nil
            let duration=segment.end-segment.start
            guard duration>0.05 else{return segment}
            let evidence=turns.filter{$0.valid && $0.end>segment.start && $0.start<segment.end}
            var coverage:[Int:Double]=[:]
            for speaker in Set(evidence.map{$0.speaker}) {
                let ranges=evidence.filter{$0.speaker==speaker && $0.confidence>=0.6}.map{(max(segment.start,$0.start),min(segment.end,$0.end))}.sorted{$0.0<$1.0}
                var end=segment.start,total=0.0
                for range in ranges {total += max(0,range.1-max(end,range.0));end=max(end,range.1)}
                coverage[speaker]=total/duration
            }
            let scores=coverage.sorted{$0.value>$1.value}
            guard let best=scores.first,best.value>=0.8 else{return segment}
            let other=evidence.filter{$0.speaker != best.key}.reduce(0.0){$0+max(0,min(segment.end,$1.end)-max(segment.start,$1.start))}/duration
            guard other<0.15 else{return segment}
            segment.speaker="Speaker "+String(best.key+1);segment.speakerSource="automatic"
            return segment
        }
    }
}
