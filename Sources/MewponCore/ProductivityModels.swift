import Foundation

public struct LocalReminder:Codable,Identifiable,Equatable,Sendable {
    public var id=UUID()
    public var title:String
    public var due:Date
    public var recurrence:String
    public var completed=false
    public init(title:String,due:Date,recurrence:String="none"){self.title=title;self.due=due;self.recurrence=recurrence}
    public func dates(after now:Date,count:Int=40,calendar:Calendar = .current)->[Date] {
        guard !completed else{return []}
        if recurrence=="none" {return due>now ? [due]:[]}
        guard ["daily","weekly"].contains(recurrence) else{return []}
        var cursor=due,result:[Date]=[],steps=0
        while result.count<count,steps<10000 {
            if cursor>now{result.append(cursor)}
            guard let next=calendar.date(byAdding:.day,value:recurrence=="daily" ? 1:7,to:cursor) else{break}
            cursor=next;steps += 1
        }
        return result
    }
}
public enum ProductivityIntents {
    public static func classify(_ input:String)->RoutingDecision? {
        guard !CommandNormalizer.hasQuotes(input),!input.contains("\n"),!input.contains(";") else{return nil}
        var s=CommandNormalizer.normalize(input)
        for prefix in ["please ","can you ","could you "] where s.hasPrefix(prefix){s=String(s.dropFirst(prefix.count))}
        func tool(_ name:String,_ args:[String:String])->RoutingDecision{.deterministic(.tool(.init(name:name,arguments:args.mapValues(JSONValue.string))))}
        if ["my reminders","show my reminders"].contains(s){return tool("local_reminders",["action":"list","title":"none","when":"none","id":"none","repeat":"none"])}
        if ["show everything due this week","what is due this week"].contains(s){return tool("productivity_due_week",[:])}
        if ["open reminders","open calendar","open productivity","draft an email"].contains(s){return tool("assistant_workspace",["workspace":"productivity"])}
        for range in ["today","tomorrow","week"] where ["show my calendar "+range,"what's on my calendar "+range,"what is on my calendar "+range].contains(s){return tool("calendar_query",["range":range])}
        guard s.hasPrefix("remind me to ") else{return nil}
        let body=String(s.dropFirst(13))
        guard !body.contains(" and "),let regex=try? NSRegularExpression(pattern:"^(.+?) (today|tomorrow)? ?(?:at )?(\\d{1,2})(?::(\\d{2}))? ?(am|pm)?$"),let match=regex.firstMatch(in:body,range:NSRange(body.startIndex...,in:body)) else {
            return .needsClarification("Give a reminder title and time, for example: remind me to study DSA tomorrow at 8 PM.")
        }
        func field(_ i:Int)->String {Range(match.range(at:i),in:body).map{String(body[$0])} ?? ""}
        var title=field(1)
        if title.hasSuffix(" at"){title=String(title.dropLast(3))}
        let day=field(2),hourText=field(3),minute=Int(field(4)) ?? 0,period=field(5)
        guard var hour=Int(hourText),(0...23).contains(hour),(0...59).contains(minute),!title.isEmpty else{return .needsClarification("Choose a valid reminder time.")}
        if !period.isEmpty{guard (1...12).contains(hour) else{return .needsClarification("Use 1–12 with AM/PM.")};hour=hour%12+(period=="pm" ? 12:0)}
        let calendar=Calendar.current,now=Date()
        var date=calendar.date(bySettingHour:hour,minute:minute,second:0,of:now)!
        if day=="tomorrow" || day.isEmpty && date<=now{date=calendar.date(byAdding:.day,value:1,to:date)!}
        if day=="today",date<=now{return .needsClarification("That time today has passed. Choose a future time.")}
        return tool("local_reminders",["action":"add","title":title,"when":ISO8601DateFormatter().string(from:date),"id":"none","repeat":"none"])
    }
}
