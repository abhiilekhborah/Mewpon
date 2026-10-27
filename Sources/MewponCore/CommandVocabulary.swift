import Foundation

/// Small, context-specific vocabulary. Literal arguments are never globally spellchecked.
public enum CommandVocabulary {
    public static func distance(_ lhs:String,_ rhs:String)->Int {
        let a=Array(lhs),b=Array(rhs)
        if a.isEmpty{return b.count};if b.isEmpty{return a.count}
        var older=Array(0...b.count),previous=older
        for i in 1...a.count {
            var row=[i]+Array(repeating:0,count:b.count)
            for j in 1...b.count {
                row[j]=min(previous[j]+1,row[j-1]+1,previous[j-1]+(a[i-1]==b[j-1] ? 0:1))
                if i>1,j>1,a[i-1]==b[j-2],a[i-2]==b[j-1]{row[j]=min(row[j],older[j-2]+1)}
            }
            older=previous;previous=row
        }
        return previous[b.count]
    }
    public static func confident(_ word:String, among choices:[String])->String? {
        if choices.contains(word){return word}
        guard word.count>=3,word.count<=24 else{return nil}
        let scored=choices.map{($0,distance(word,$0))}.sorted{$0.1<$1.1}
        guard let best=scored.first,best.1<=1,scored.count<2 || scored[1].1>best.1 else{return nil}
        return best.0
    }
    public static func command(_ input:String)->String {
        if ["vs cod","vs code","vscode"].contains(input){return "open vs code"}
        if ["btry lvl","battery level","btry","battery percentage"].contains(input){return "battery"}
        if input.hasPrefix("vol "),let level=Int(input.dropFirst(4).replacingOccurrences(of:"%",with:"")),(0...100).contains(level){return "set volume to \(level)"}
        var words=input.split(separator:" ").map(String.init)
        guard let first=words.first else{return input}
        let aliases=["opn":"open","opne":"open","fnd":"find","serch":"search","srch":"search","whr":"where","lauch":"launch","lanuch":"launch"]
        words[0]=aliases[first] ?? confident(first,among:["open","launch","find","search","show"]) ?? first
        if words[0]=="where",words.count>1,words[1] != "is"{words.insert("is",at:1)}
        if ["open","show","launch"].contains(words[0]),words.count==2 {
            let folders=["dwnloads":"downloads","docs":"documents"]
            words[1]=folders[words[1]] ?? confident(words[1],among:["downloads","documents","desktop","home"]) ?? words[1]
        }
        if words[0]=="open" || words[0]=="launch" {
            let arg=words.dropFirst().joined(separator:" ")
            if arg=="vs cod"{return "open vs code"}
            if words.count==2,!arg.contains("."),!arg.contains("/"),let known=confident(arg,among:["safari","finder","terminal","notes","calendar"]){return words[0]+" "+known}
        }
        return words.joined(separator:" ")
    }
    public static func isPythonProject(_ input:String)->Bool {
        let words=input.split(separator:" ").map(String.init)
        return !words.contains(where:{$0.contains("/") || $0.contains(".")}) && words.contains(where:{["py","python"].contains($0)}) && words.contains(where:{["project","projects","proj","prj","prjct"].contains($0)}) && words.allSatisfy{["my","the","last","latest","recent","python","py","project","projects","proj","prj","prjct","in","vs","cod","code","vscode"].contains($0)}
    }
    public static func searchTokens(_ text:String)->[String] {
        let aliases=["cv":"resume","résumé":"resume","internshp":"internship","repot":"report","repo":"report","prjct":"project","prj":"project","proj":"project","py":"python","ystrday":"yesterday","ppt":"presentations"]
        let stop:Set<String>=["my","the","that","with","and","file","files","named","i","made","me","a","of"]
        return text.lowercased().split(whereSeparator:{!$0.isLetter && !$0.isNumber && $0 != "_"}).map(String.init).filter{!stop.contains($0)}.map{aliases[$0] ?? $0}
    }
}
