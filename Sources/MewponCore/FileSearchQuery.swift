import Foundation

/// Parsed search metadata only, never cached paths or file contents.
public struct FileSearchQuery:Equatable,Sendable {
    public enum Period:Sendable {case any,recent,lastWeek,yesterday,thisMonth}
    public var largest: Bool = false
    public var screenshots: Bool = false
    public var name:String;public var extensions:[String];public var period:Period
    public static func parse(_ input:String)->Self {
        var s=CommandNormalizer.normalize(input);var ext:[String]=[];var period:Period = .any
        for (phrase, value) in [("from yesterday", Period.yesterday), ("from this month", .thisMonth), ("this month", .thisMonth), ("i edited last week", .lastWeek)] where s.contains(phrase) { period = value; s = s.replacingOccurrences(of: phrase, with: "").trimmingCharacters(in: .whitespaces) }
        if s.contains("yesterday"){period = .yesterday;s=s.replacingOccurrences(of:"yesterday",with:"")}
        if s.contains("ystrday"){period = .yesterday;s=s.replacingOccurrences(of:"ystrday",with:"")}
        if s.hasPrefix("everything named ") { s = String(s.dropFirst(17)) }
        if s.contains("from last week"){period = .lastWeek;s=s.replacingOccurrences(of:"from last week",with:"")}
        let largest = s.hasPrefix("largest ")
        if largest { s = String(s.dropFirst(8)) }
        if s.hasPrefix("recent "){period = .recent;s=String(s.dropFirst(7))}
        let types:[(String,[String])]=[("python file",["py"]),("pdfs",["pdf"]),("pdf",["pdf"]),("presentations",["ppt","pptx","key"]),("presentation",["ppt","pptx","key"]),("screenshots",["png"]),("videos",["mov","mp4","m4v"]),("images",["png","jpg","jpeg","heic"])]
        for (label,types) in types where s==label || s.hasPrefix(label+" ") {
            ext=types;s=String(s.dropFirst(label.count)).trimmingCharacters(in:.whitespaces);break
        }
        if ext.isEmpty {
            for (label,types) in types {
                let tokens=s.split(separator:" ").map(String.init)
                if tokens.contains(label){ext=types;s=tokens.filter{$0 != label}.joined(separator:" ");break}
            }
            if ext.isEmpty,s.split(separator:" ").contains("ppt"){ext=["ppt","pptx","key"];s=s.replacingOccurrences(of:"ppt",with:"")}
        }
        if s.hasPrefix("named "){s=String(s.dropFirst(6))}
        var result = Self(name:s.trimmingCharacters(in:.whitespaces),extensions:ext,period:period)
        result.largest = largest
        result.screenshots = CommandNormalizer.normalize(input).hasPrefix("screenshots")
        return result
    }
    public func modifiedInterval(now:Date=Date(),calendar:Calendar = .current)->DateInterval? {
        var calendar=calendar;calendar.firstWeekday=2
        switch period {
        case .any:return nil
        case .yesterday:
            let end = calendar.startOfDay(for: now)
            return DateInterval(start: calendar.date(byAdding: .day, value: -1, to: end)!, end: end)
        case .thisMonth: return DateInterval(start: calendar.dateInterval(of: .month, for: now)!.start, end: now)
        case .recent:return DateInterval(start:calendar.date(byAdding:.day,value:-30,to:now)!,end:now)
        case .lastWeek:
            let end=calendar.dateInterval(of:.weekOfYear,for:now)!.start
            return DateInterval(start:calendar.date(byAdding:.day,value:-7,to:end)!,end:end)
        }
    }
}
