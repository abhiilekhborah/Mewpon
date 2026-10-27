import Foundation

public struct ProactivePreferences:Codable,Equatable,Sendable {
    public var meetingAlerts=false
    public var dailyBriefing=false
    public var hour=8
    public var minute=0
    public var paused=false
    public init(){}
    public var valid:Bool{(0...23).contains(hour) && (0...59).contains(minute)}
    public func shouldBrief(now:Date,lastDay:String?,calendar:Calendar = .current)->Bool {
        guard valid,dailyBriefing,!paused,calendar.component(.hour,from:now)==hour,calendar.component(.minute,from:now)==minute else{return false}
        return Self.dayKey(now,calendar:calendar) != lastDay
    }
    public static func dayKey(_ date:Date,calendar:Calendar = .current)->String {
        let c=calendar.dateComponents([.year,.month,.day],from:date)
        return String(c.year ?? 0)+"-"+String(c.month ?? 0)+"-"+String(c.day ?? 0)+"@"+calendar.timeZone.identifier
    }
}
