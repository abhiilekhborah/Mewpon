import Foundation

public enum SlideChange {
    /// Small cursor movements and repeated frames do not produce new slides.
    public static func meaningful(previous:[UInt8]?,current:[UInt8])->Bool {
        guard !current.isEmpty else{return false}
        guard let previous,previous.count==current.count else{return true}
        let differences=zip(previous,current).map{abs(Int($0)-Int($1))}
        let mean=Double(differences.reduce(0,+))/Double(current.count)
        let changed=Double(differences.filter{$0>24}.count)/Double(current.count)
        return mean>12 && changed>0.08
    }
}
