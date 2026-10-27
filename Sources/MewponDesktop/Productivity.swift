import AppKit
import SwiftUI
import EventKit
import Contacts
import UserNotifications
import MewponCore

@MainActor final class ReminderLibrary:ObservableObject {
    @Published private(set) var items:[LocalReminder]=[]
    @Published var issue:String?
    @Published var notificationsEnabled=UserDefaults.standard.bool(forKey:"reminderNotificationsV7")
    @Published var paused=UserDefaults.standard.bool(forKey:"pauseRemindersV7")
    let storage:PrivateLibrary
    private let recordID=UUID(uuidString:"00000000-0000-0000-0000-000000000007")!
    private var scheduling:Task<Void,Never>?
    init(storage:PrivateLibrary=PrivateLibrary(),notificationsEnabled:Bool?=nil) {
        self.storage=storage
        if let notificationsEnabled{self.notificationsEnabled=notificationsEnabled}
        items=(try? storage.load([LocalReminder].self,id:recordID,kind:"reminders")) ?? []
        if self.notificationsEnabled{Task{await schedule()}}
    }
    func persist() throws {try storage.save(items,id:recordID,kind:"reminders")}
    func add(title:String,due:Date,recurrence:String) async throws ->LocalReminder {
        guard !title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,title.count<=300,due>Date(),["none","daily","weekly"].contains(recurrence),items.count<200 else{throw MewponError.invalid("Use a short title, a future time, and none/daily/weekly recurrence; limit 200 reminders.")}
        if let existing=items.first(where:{$0.title==title && abs($0.due.timeIntervalSince(due))<1 && !$0.completed}){return existing}
        let item=LocalReminder(title:title,due:due,recurrence:recurrence);let prior=items;items.append(item)
        do{try persist()}catch{items=prior;throw error}
        if notificationsEnabled{await schedule()};return item
    }
    func complete(_ id:UUID) async throws {
        guard let i=items.firstIndex(where:{$0.id==id}) else{throw MewponError.invalid("Choose an existing reminder.")}
        let prior=items
        if items[i].recurrence=="none"{items[i].completed=true}
        else{guard let next=items[i].dates(after:max(Date(),items[i].due),count:1).first else{throw MewponError.invalid("Next recurrence unavailable.")};items[i].due=next}
        do{try persist()}catch{items=prior;throw error};if notificationsEnabled{await schedule()}
    }
    func enableNotifications() async {
        do{notificationsEnabled=try await UNUserNotificationCenter.current().requestAuthorization(options:[.alert,.sound]);UserDefaults.standard.set(notificationsEnabled,forKey:"reminderNotificationsV7");await schedule()}catch{issue=error.localizedDescription}
    }
    func schedule() async {
        let previous=scheduling;previous?.cancel()
        let job=Task{await previous?.value;guard !Task.isCancelled else{return};await applySchedule()}
        scheduling=job;await job.value
    }
    private func applySchedule() async {
        let center=UNUserNotificationCenter.current()
        let pending=await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(withIdentifiers:pending.filter{$0.identifier.hasPrefix("mewpon-reminder-")}.map{$0.identifier})
        guard notificationsEnabled,!paused else{return}
        let settings=await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else{issue="Notifications are not allowed. Reminders remain saved locally.";return}
        let upcoming=items.flatMap{item in item.dates(after:.now).map{(item,$0)}}.sorted{$0.1<$1.1}.prefix(40)
        for (i,value) in upcoming.enumerated(){
            guard !Task.isCancelled,!paused,notificationsEnabled else{return}
            let content=UNMutableNotificationContent();content.title="Mewpon reminder";content.body=value.0.title;content.sound = .default
            let trigger=UNTimeIntervalNotificationTrigger(timeInterval:max(1,value.1.timeIntervalSinceNow),repeats:false)
            do{try await center.add(UNNotificationRequest(identifier:"mewpon-reminder-\(value.0.id)-\(i)",content:content,trigger:trigger))}catch{issue=error.localizedDescription}
        }
    }
}
@MainActor final class CalendarAccess:ObservableObject {
    private lazy var store=EKEventStore()
    @Published var events:[EKEvent]=[]
    @Published var reminders:[EKReminder]=[]
    @Published var calendars:[EKCalendar]=[]
    @Published var allowAccountWrites=false
    @Published var selectedCalendar=""
    @Published var issue:String?
    var canRead:Bool{EKEventStore.authorizationStatus(for:.event) == .fullAccess}
    var canReadReminders:Bool{EKEventStore.authorizationStatus(for:.reminder) == .fullAccess}
    func requestCalendar() async {do{_ = try await store.requestFullAccessToEvents();refresh()}catch{issue=error.localizedDescription}}
    func requestReminders() async {do{_ = try await store.requestFullAccessToReminders();await refreshReminders()}catch{issue=error.localizedDescription}}
    func refresh() {
        guard canRead else{events=[];calendars=[];return}
        calendars=store.calendars(for:.event).filter{$0.allowsContentModifications}
        let start=Calendar.current.startOfDay(for:.now),end=Calendar.current.date(byAdding:.day,value:7,to:start)!
        events=store.events(matching:store.predicateForEvents(withStart:start,end:end,calendars:nil)).sorted{$0.startDate<$1.startDate}
    }
    func refreshReminders() async {
        guard canReadReminders else{reminders=[];return}
        let predicate=store.predicateForIncompleteReminders(withDueDateStarting:nil,ending:Calendar.current.date(byAdding:.day,value:7,to:.now),calendars:nil)
        reminders=await withCheckedContinuation{c in store.fetchReminders(matching:predicate){c.resume(returning:$0 ?? [])}}
    }
    func query(_ range:String)->ToolResult {
        guard ["today","tomorrow","week"].contains(range) else{return ToolResult(false,"Choose today, tomorrow or week.")}
        guard canRead else{return ToolResult(false,"Enable Calendar access once in Productivity. No calendar data was read.")}
        let calendarNames=store.calendars(for:.event).filter{$0.allowsContentModifications}.map{$0.title+" ["+$0.calendarIdentifier+"]"}.joined(separator:"; ")
        let cal=Calendar.current,today=cal.startOfDay(for:.now),start=range=="tomorrow" ? cal.date(byAdding:.day,value:1,to:today)!:today,end=cal.date(byAdding:.day,value:range=="week" ? 7:1,to:start)!
        let values=store.events(matching:store.predicateForEvents(withStart:start,end:end,calendars:nil)).sorted{$0.startDate<$1.startDate}.prefix(40)
        return ToolResult(true,(values.isEmpty ? "No events in this authorized calendar range.":values.map{"\($0.startDate.formatted(date:.abbreviated,time:.shortened)): \($0.title ?? "Untitled") [\($0.eventIdentifier ?? "") ]"}.joined(separator:"\n"))+"\nWritable calendars: "+calendarNames)
    }
    func write(id:String,title:String,start:Date,end:Date,calendarID:String,recurrence:String) throws ->ToolResult {
        guard canRead,!title.isEmpty,title.count<=300,end>start,end.timeIntervalSince(start)<=86400,["none","daily","weekly"].contains(recurrence),let calendar=store.calendar(withIdentifier:calendarID),calendar.allowsContentModifications else{throw MewponError.invalid("Choose an authorized writable calendar and a valid event (up to 24 hours).")}
        guard calendar.source.sourceType == .local || allowAccountWrites else{throw MewponError.invalid("This calendar belongs to an account. Explicitly enable account writes in Productivity; the OS may synchronize them online.")}
        let event:EKEvent
        if id=="none"{event=EKEvent(eventStore:store)}else{guard let known=store.event(withIdentifier:id),known.calendar.calendarIdentifier==calendarID else{throw MewponError.invalid("Choose an exact existing event from this calendar.")};event=known}
        let conflicts=store.events(matching:store.predicateForEvents(withStart:start,end:end,calendars:nil)).filter{$0.eventIdentifier != event.eventIdentifier}
        guard conflicts.isEmpty else{return ToolResult(false,"Schedule conflict: "+conflicts.prefix(3).map{$0.title ?? "Untitled"}.joined(separator:", ")+". Choose another time; nothing was saved.")}
        event.title=title;event.startDate=start;event.endDate=end;event.calendar=calendar
        event.recurrenceRules=recurrence=="none" ? nil:[EKRecurrenceRule(recurrenceWith:recurrence=="daily" ? .daily:.weekly,interval:1,end:nil)]
        try store.save(event,span:.thisEvent,commit:true)
        guard let saved=store.event(withIdentifier:event.eventIdentifier),saved.title==title,abs(saved.startDate.timeIntervalSince(start))<1,abs(saved.endDate.timeIntervalSince(end))<1 else{return ToolResult(false,"Calendar accepted a save, but readback could not verify it.")}
        refresh();return ToolResult(true,"Saved calendar event: "+title+" · "+start.formatted(date:.abbreviated,time:.shortened))
    }
    func addReminder(title:String,due:Date) throws ->ToolResult {
        guard !title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,title.count<=300,due>Date() else{throw MewponError.invalid("Enter a short reminder title and a future due time.")}
        guard canReadReminders,let calendar=store.defaultCalendarForNewReminders() else{throw MewponError.unavailable("Enable Reminders access and choose a writable list in the Reminders app first.")}
        guard calendar.source.sourceType == .local || allowAccountWrites else{throw MewponError.invalid("This reminder list may sync to an account. Enable account writes explicitly first.")}
        let reminder=EKReminder(eventStore:store);reminder.title=title;reminder.calendar=calendar;reminder.dueDateComponents=Calendar.current.dateComponents([.year,.month,.day,.hour,.minute],from:due)
        try store.save(reminder,commit:true)
        guard store.calendarItem(withIdentifier:reminder.calendarItemIdentifier) != nil else{return ToolResult(false,"Reminder save was not verified.")}
        return ToolResult(true,"Saved in the authorized macOS Reminders list.")
    }
    func completeReminder(_ id:String) throws {
        guard canReadReminders,let reminder=store.calendarItem(withIdentifier:id) as? EKReminder else{throw MewponError.invalid("Choose an authorized reminder.")}
        guard reminder.calendar.source.sourceType == .local || allowAccountWrites else{throw MewponError.invalid("Enable account writes before changing this synchronized reminder.")}
        reminder.isCompleted=true;try store.save(reminder,commit:true)
    }
}
struct ContactChoice:Identifiable {let id:String;let name:String;let phones:[String];let emails:[String]}
@MainActor final class ContactAccess:ObservableObject {
    private lazy var store=CNContactStore()
    @Published var matches:[ContactChoice]=[]
    @Published var query=""
    @Published var status="Not searched"
    @Published var issue:String?
    var authorized:Bool {CNContactStore.authorizationStatus(for:.contacts) == .authorized}
    func request() async {do{_ = try await store.requestAccess(for:.contacts);status=authorized ? "Contacts access granted":"Contacts access not granted"}catch{issue=error.localizedDescription}}
    func search() {
        guard authorized,!query.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else{matches=[];issue="Authorize Contacts and enter a name first.";return}
        issue=nil
        do{matches=try store.unifiedContacts(matching:CNContact.predicateForContacts(matchingName:query),keysToFetch:[CNContactIdentifierKey as CNKeyDescriptor,CNContactFormatter.descriptorForRequiredKeys(for:.fullName),CNContactPhoneNumbersKey as CNKeyDescriptor,CNContactEmailAddressesKey as CNKeyDescriptor]).prefix(20).map{ContactChoice(id:$0.identifier,name:CNContactFormatter.string(from:$0,style:.fullName) ?? "Unnamed",phones:$0.phoneNumbers.map{$0.value.stringValue},emails:$0.emailAddresses.map{$0.value as String})};status="Found "+String(matches.count)+" authorized contact matches"}
        catch{issue=error.localizedDescription}
    }
}
struct LocalRemindersTool:AssistantTool {
    let spec=ToolSpec("local_reminders","Save/list/complete encrypted local reminders. Does not access an external account. Notifications require a separate opt-in.",fields:["action":"add, list, complete","title":"Reminder title or none","when":"ISO 8601 future due time or none","id":"Exact reminder UUID or none","repeat":"none, daily, weekly"],capability:.systemControl)
    func execute(arguments:[String:JSONValue]) async throws ->ToolResult {
        guard let library=await MainActor.run(body:{AppCoordinator.shared?.model.reminders}) else{return ToolResult(false,"Local reminder service unavailable.")}
        switch arguments["action"]?.string {
        case "list":return await MainActor.run {let values=library.items.filter{!$0.completed}.sorted{$0.due<$1.due}.prefix(40);return ToolResult(true,values.isEmpty ? "No pending local reminders.":values.map{"\($0.title) · \($0.due.formatted()) · \($0.id.uuidString)"}.joined(separator:"\n"))}
        case "add":guard let date=ISO8601DateFormatter().date(from:arguments["when"]!.string!) else{return ToolResult(false,"Use an exact future reminder time.")};let item=try await library.add(title:arguments["title"]!.string!,due:date,recurrence:arguments["repeat"]!.string!);let enabled=await library.notificationsEnabled;return ToolResult(true,"Saved local reminder: \(item.title) · \(item.due.formatted())."+(enabled ? "":" Notifications are not enabled; it remains visible in Reminders."))
        case "complete":guard let id=UUID(uuidString:arguments["id"]!.string!) else{return ToolResult(false,"Choose an exact reminder ID.")};try await library.complete(id);return ToolResult(true,"Reminder updated locally.")
        default:return ToolResult(false,"Unsupported reminder action.")
        }
    }
}
struct DueWeekTool:AssistantTool {
    let spec=ToolSpec("productivity_due_week","List local tasks due through the next seven days, plus already authorized Calendar and macOS Reminders. Does not request account or OS access.")
    @MainActor private func collect() async ->ToolResult {
        guard let model=AppCoordinator.shared?.model else{return ToolResult(false,"Productivity is unavailable.")}
        let end=Calendar.current.date(byAdding:.day,value:7,to:.now)!
        let local=model.reminders.items.filter{!$0.completed && $0.due<=end}.sorted{$0.due<$1.due}.prefix(40)
        var parts=["Local reminders:\n"+(local.isEmpty ? "None due.":local.map{$0.title+" · "+$0.due.formatted()}.joined(separator:"\n"))]
        parts.append("Calendar:\n"+model.calendar.query("week").summary)
        if model.calendar.canReadReminders {
            await model.calendar.refreshReminders()
            let values=model.calendar.reminders.prefix(40).map{($0.title ?? "Untitled")+" · "+($0.dueDateComponents?.date?.formatted() ?? "No due date")}
            parts.append("macOS Reminders:\n"+(values.isEmpty ? "None due.":values.joined(separator:"\n")))
        }else{parts.append("macOS Reminders not authorized; those lists were not read.")}
        return ToolResult(true,parts.joined(separator:"\n\n"))
    }
    func execute(arguments:[String:JSONValue]) async throws ->ToolResult{await collect()}
}
struct ContactQueryTool:AssistantTool {
    let spec=ToolSpec("contact_query","Search an already authorized contact by name for phone/email. Does not send messages, call, read contact notes or request permission.",fields:["name":"Contact name"],capability:.context)
    func execute(arguments:[String:JSONValue]) async throws ->ToolResult {
        await MainActor.run {
            guard let contacts=AppCoordinator.shared?.model.contacts,let name=arguments["name"]?.string,!name.isEmpty,name.count<=100 else{return ToolResult(false,"Enter a contact name.")}
            guard contacts.authorized else{return ToolResult(false,"Authorize Contacts once in Productivity. No contacts were read.")}
            contacts.query=name;contacts.search()
            guard contacts.issue==nil else{return ToolResult(false,contacts.issue!)}
            return ToolResult(true,contacts.matches.isEmpty ? "No matching authorized contacts.":contacts.matches.map{$0.name+" · "+($0.phones+$0.emails).joined(separator:", ")}.joined(separator:"\n"))
        }
    }
}
struct CalendarQueryTool:AssistantTool {
    let spec=ToolSpec("calendar_query","Read events from calendars already authorized through EventKit. Does not connect accounts or request permission automatically.",fields:["range":"today, tomorrow, week"],capability:.systemControl)
    func execute(arguments:[String:JSONValue]) async throws ->ToolResult {await MainActor.run {AppCoordinator.shared?.model.calendar.query(arguments["range"]!.string!) ?? ToolResult(false,"Calendar unavailable.")}}
}
struct CalendarWriteTool:AssistantTool {
    let spec=ToolSpec("calendar_write","Create/update an exact authorized event with conflict detection and readback. Account writes require explicit opt-in.",fields:["id":"none for create, exact event ID for update","title":"Event title","start":"ISO 8601 time","end":"ISO 8601 time","calendar":"Exact writable calendar ID","repeat":"none, daily, weekly"],capability:.systemControl)
    func execute(arguments:[String:JSONValue]) async throws ->ToolResult {
        guard let start=ISO8601DateFormatter().date(from:arguments["start"]!.string!),let end=ISO8601DateFormatter().date(from:arguments["end"]!.string!) else{return ToolResult(false,"Specify exact start and end times.")}
        return try await MainActor.run {guard let service=AppCoordinator.shared?.model.calendar else{return ToolResult(false,"Calendar unavailable.")};return try service.write(id:arguments["id"]!.string!,title:arguments["title"]!.string!,start:start,end:end,calendarID:arguments["calendar"]!.string!,recurrence:arguments["repeat"]!.string!)}
    }
}

struct ProductivityWorkspaceView:View {
    @ObservedObject var reminders:ReminderLibrary
    @ObservedObject var calendar:CalendarAccess
    @ObservedObject var contacts:ContactAccess
    @State private var title=""
    @State private var due=Date().addingTimeInterval(3600)
    @State private var end=Date().addingTimeInterval(7200)
    @State private var recurrence="none"
    @State private var eventID="none"
    @State private var recipient=""
    @State private var subject=""
    @State private var bodyText=""
    @State private var attachments:[URL]=[]
    @State private var approveDraft=false
    @State private var message=""
    var body:some View {
        TabView {
            Form {
                Section("Local encrypted reminders") {
                    TextField("What should I remember?",text:$title)
                    DatePicker("Due",selection:$due)
                    Picker("Repeat",selection:$recurrence){Text("Once").tag("none");Text("Daily").tag("daily");Text("Weekly").tag("weekly")}
                    Button("Save local reminder"){Task{do{_ = try await reminders.add(title:title,due:due,recurrence:recurrence);message="Saved locally."}catch{message=error.localizedDescription}}}
                    ForEach(reminders.items.filter{!$0.completed}.sorted{$0.due<$1.due}){item in HStack{VStack(alignment:.leading){Text(item.title);Text(item.due,style:.date)+Text(" ")+Text(item.due,style:.time)};Spacer();Button("Complete"){Task{do{try await reminders.complete(item.id)}catch{message=error.localizedDescription}}}} }
                }
                Section("Opt-in reminders") {
                    Button("Enable reminder notifications…"){Task{await reminders.enableNotifications()}}
                    Toggle("Pause reminder notifications",isOn:$reminders.paused).onChange(of:reminders.paused){_,v in UserDefaults.standard.set(v,forKey:"pauseRemindersV7");Task{await reminders.schedule()}}
                    Text(reminders.notificationsEnabled ? "Notifications enabled · next 40 occurrences scheduled; reopen Mewpon to replenish the horizon.":"Notifications off · reminders are stored and shown locally.").font(.caption)
                    if let issue=reminders.issue{Text(issue).foregroundStyle(.orange)}
                }
            }.formStyle(.grouped).tabItem{Label("Reminders",systemImage:"checklist")}
            Form {
                Section("Calendar access") {
                    Text(calendar.canRead ? "Calendar: granted":"Calendar: not granted")
                    Button("Authorize Calendar…"){Task{await calendar.requestCalendar()}}
                    Toggle("Allow writes to account calendars and lists",isOn:$calendar.allowAccountWrites)
                    Text("Account calendars may synchronize through macOS. Google/Microsoft access exists only if that account is already connected in macOS; Mewpon does not create an account connection.").font(.caption)
                    Button("Refresh upcoming week"){calendar.refresh()}
                    ForEach(calendar.events,id:\.eventIdentifier){event in HStack{Text(event.title ?? "Untitled");Text(event.startDate,style:.date);Text(event.startDate,style:.time);Spacer();Button("Edit"){eventID=event.eventIdentifier;title=event.title;due=event.startDate;end=event.endDate;calendar.selectedCalendar=event.calendar.calendarIdentifier}}}
                }
                Section("Create or edit an event") {
                    TextField("Title",text:$title);DatePicker("Start",selection:$due);DatePicker("End",selection:$end)
                    Picker("Calendar",selection:$calendar.selectedCalendar){Text("Choose a writable calendar").tag("");ForEach(calendar.calendars,id:\.calendarIdentifier){c in Text(c.title+" · "+c.source.title).tag(c.calendarIdentifier)}}
                    Picker("Repeat",selection:$recurrence){Text("Once").tag("none");Text("Daily").tag("daily");Text("Weekly").tag("weekly")}
                    HStack{Button(eventID=="none" ? "Create event":"Save selected event"){do{message=try calendar.write(id:eventID,title:title,start:due,end:end,calendarID:calendar.selectedCalendar,recurrence:recurrence).summary}catch{message=error.localizedDescription}}.disabled(calendar.selectedCalendar.isEmpty);Button("New event"){eventID="none"}}
                    if let issue=calendar.issue{Text(issue).foregroundStyle(.orange)}
                }
                Section("macOS Reminders · optional") {
                    Text(calendar.canReadReminders ? "macOS Reminders: granted":"macOS Reminders: not granted")
                    Button("Authorize macOS Reminders…"){Task{await calendar.requestReminders()}}
                    Button("Refresh due reminders"){Task{await calendar.refreshReminders()}}
                    Button("Add above title and due date to macOS Reminders"){do{message=try calendar.addReminder(title:title,due:due).summary}catch{message=error.localizedDescription}}
                    ForEach(calendar.reminders,id:\.calendarItemIdentifier){reminder in HStack{Text(reminder.title);Spacer();Button("Complete"){do{try calendar.completeReminder(reminder.calendarItemIdentifier);Task{await calendar.refreshReminders()}}catch{message=error.localizedDescription}}}}
                }
            }.formStyle(.grouped).tabItem{Label("Calendar",systemImage:"calendar")}
            Form {
                Section("Contacts · searched only on request") {
                    Text(contacts.authorized ? "Contacts: granted":"Contacts: not granted")
                    Text(contacts.status).font(.caption)
                    Button("Authorize Contacts…"){Task{await contacts.request()}}
                    TextField("Name",text:$contacts.query).onSubmit{contacts.search()}
                    Button("Search authorized contacts"){contacts.search()}
                    ForEach(contacts.matches){contact in VStack(alignment:.leading){Text(contact.name).font(.headline);ForEach(contact.phones,id:\.self){Text($0).textSelection(.enabled)};ForEach(contact.emails,id:\.self){email in HStack{Text(email).textSelection(.enabled);Button("Prepare email"){recipient=email;subject="";bodyText="";message="Recipient selected. Review the Email tab before opening a draft."}}}}}
                    if let issue=contacts.issue{Text(issue).foregroundStyle(.orange)}
                    Text("No contact notes, photos or full-address-book scans. Calls/messages are completed in their native applications; Mewpon does not use private calling APIs.").font(.caption)
                }
            }.formStyle(.grouped).tabItem{Label("Contacts",systemImage:"person.crop.circle")}
            Form {
                Section("Review an email draft") {
                    TextField("To",text:$recipient);TextField("Subject",text:$subject);TextEditor(text:$bodyText).frame(minHeight:180)
                    Button("Attach a local file…"){let p=NSOpenPanel();if p.runModal() == .OK,let url=p.url{attachments.append(url)}}
                    ForEach(attachments,id:\.self){url in Text(url.lastPathComponent)}
                    Toggle("I approve opening this draft in Mail; account drafts may sync",isOn:$approveDraft)
                    Button("Open reviewed draft in Mail") {
                        guard let service=NSSharingService(named:.composeEmail),!recipient.isEmpty,!bodyText.isEmpty else{message="Configure Mail and enter a recipient and body first.";return}
                        service.recipients=[recipient];service.subject=subject;service.perform(withItems:[bodyText]+attachments.map{$0 as Any});message="Requested Mail’s draft editor. Nothing was sent by Mewpon."
                    }.disabled(!approveDraft)
                    Text("Mewpon does not send this email. Review recipients, attachments and content in Mail, then send there yourself. Account email search is not connected.").font(.caption)
                }
            }.formStyle(.grouped).tabItem{Label("Email draft",systemImage:"envelope")}
        }.padding(12).overlay(alignment:.bottomLeading){if !message.isEmpty{Text(message).font(.caption).padding(10).background(.regularMaterial)}}.frame(minWidth:800,minHeight:650)
    }
}
