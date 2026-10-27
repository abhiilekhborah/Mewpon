import Foundation

public func elapsedMilliseconds(since start: ContinuousClock.Instant) -> Double {
    let c=start.duration(to: .now).components
    return Double(c.seconds)*1000+Double(c.attoseconds)/1e15
}

/// Bounded metadata only: no prompts, arguments, paths, results, or approvals.
public actor PerformanceProfiler {
    public static let shared=PerformanceProfiler()
    private var samples:[String:[Double]]=[:]
    public private(set) var peakResidentBytes:Int64=0
    public func recordPeakResidentBytes(_ bytes:Int64){peakResidentBytes=max(peakResidentBytes,bytes)}
    public func record(_ category:String, milliseconds:Double){
        guard milliseconds.isFinite, milliseconds>=0, samples[category] != nil || samples.count<64 else{return}
        var values=samples[category] ?? [];if values.count>=512{values.removeFirst()};values.append(milliseconds);samples[category]=values
    }
    public func record(_ category:String,since start:ContinuousClock.Instant){record(category,milliseconds:elapsedMilliseconds(since:start))}
    public func snapshot()->[String:Summary]{samples.mapValues(Summary.init)}
    public func clear(){samples.removeAll(keepingCapacity:true);peakResidentBytes=0}
    public func reportJSON() throws ->Data {
        struct Report:Encodable {let latencies:[String:Summary];let peakMainProcessResidentBytes:Int64;let note:String}
        let report=Report(latencies:snapshot(),peakMainProcessResidentBytes:peakResidentBytes,note:"Monotonic durations in milliseconds. UI assignments and bridge round trips are not display-paint latency. RSS excludes WebKit and Ollama. No prompts, paths, results or permissions are recorded.")
        let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys];return try encoder.encode(report)
    }
    public struct Summary:Codable,Sendable {
        public let count:Int;public let p50ms:Double;public let p95ms:Double?;public let p99ms:Double?;public let maximumMs:Double
        init(_ values:[Double]){let s=values.sorted();count=s.count
            func percentile(_ p:Double)->Double{s[min(s.count-1,max(0,Int(ceil(Double(s.count)*p))-1))]}
            p50ms=percentile(0.5);p95ms=s.count>=20 ? percentile(0.95):nil;p99ms=s.count>=100 ? percentile(0.99):nil;maximumMs=s.last ?? 0
        }
    }
}

/// Small in-memory cache. Expiration never grants permission or replays effects.
public actor BoundedCache<Key:Hashable & Sendable,Value:Sendable> {
    private struct Entry {let value:Value;let expires:ContinuousClock.Instant;var used:UInt64}
    private var entries:[Key:Entry]=[:];private var counter:UInt64=0
    private let capacity:Int;private let ttl:Duration
    public init(capacity:Int,ttl:Duration){self.capacity=max(1,capacity);self.ttl=ttl}
    public func value(for key:Key)->Value?{
        guard var entry=entries[key] else{return nil}
        guard ContinuousClock.now<entry.expires else{entries[key]=nil;return nil}
        counter &+= 1;entry.used=counter;entries[key]=entry;return entry.value
    }
    public func insert(_ value:Value,for key:Key){
        counter &+= 1
        if entries[key]==nil,entries.count>=capacity,let oldest=entries.min(by:{$0.value.used<$1.value.used})?.key{entries[oldest]=nil}
        entries[key]=Entry(value:value,expires:.now.advanced(by:ttl),used:counter)
    }
    public func removeAll(){entries.removeAll(keepingCapacity:true)}
    public var count:Int{entries.count}
}
