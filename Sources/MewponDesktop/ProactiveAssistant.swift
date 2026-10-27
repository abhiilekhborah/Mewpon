import Foundation
import SwiftUI
import UserNotifications
import MewponCore

@MainActor final class ProactiveAssistant:ObservableObject {
    @Published var preferences:ProactivePreferences {
        didSet{if let data=try? JSONEncoder().encode(preferences){UserDefaults.standard.set(data,forKey:"proactivePreferencesV7")};start()}
    }
    @Published private(set) var status="Off · no monitoring"
    private let reminders:ReminderLibrary
    private let calendar:CalendarAccess
    private var worker:Task<Void,Never>?
    private var lastRefresh=Date.distantPast
    private var lastDay=UserDefaults.standard.string(forKey:"lastDailyBriefV7")
    init(reminders:ReminderLibrary,calendar:CalendarAccess) {
        self.reminders=reminders;self.calendar=calendar
        let stored=UserDefaults.standard.data(forKey:"proactivePreferencesV7").flatMap{try? JSONDecoder().decode(ProactivePreferences.self,from:$0)}
        preferences=stored?.valid==true ? stored!:ProactivePreferences()
    }
    func start() {
        let previous=worker;previous?.cancel();worker=nil
        guard !preferences.paused,preferences.meetingAlerts || preferences.dailyBriefing else {
            status=preferences.paused ? "Paused · monitoring stopped":"Off · no monitoring"
            if reminders.notificationsEnabled {
                worker=Task{await removeMeetingAlerts();await previous?.value;await removeMeetingAlerts();UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers:["mewpon-daily-brief"])}
            }
            return
        }
        guard reminders.notificationsEnabled else{status="Enable notifications first; no monitoring started";return}
        lastRefresh = .distantPast
        worker=Task{[weak self] in
            await previous?.value
            while let self,!Task.isCancelled {
                await tick()
                do{try await Task.sleep(for:.seconds(30))}catch{break}
            }
        }
    }
    func stop() {worker?.cancel();worker=nil}
    func pause() {preferences.paused=true}
    private func removeMeetingAlerts() async {
        let center=UNUserNotificationCenter.current(),requests=await UNUserNotificationCenter.current().pendingNotificationRequests()
        center.removePendingNotificationRequests(withIdentifiers:requests.filter{$0.identifier.hasPrefix("mewpon-meeting-")}.map{$0.identifier})
    }
    private func tick() async {
        guard !Task.isCancelled,!preferences.paused,reminders.notificationsEnabled else{return}
        let now=Date()
        if preferences.meetingAlerts,now.timeIntervalSince(lastRefresh)>=300 {
            lastRefresh=now
            if calendar.canRead {
                calendar.refresh()
                await removeMeetingAlerts()
                for event in calendar.events.filter({!$0.isAllDay && $0.startDate>now}).prefix(20) {
                    guard !Task.isCancelled,!preferences.paused,preferences.meetingAlerts else{return}
                    let content=UNMutableNotificationContent();content.title="Upcoming calendar event";content.body=String((event.title ?? "Untitled").prefix(200))+" · "+event.startDate.formatted(date:.omitted,time:.shortened);content.sound = .default
                    let trigger=UNTimeIntervalNotificationTrigger(timeInterval:max(1,event.startDate.addingTimeInterval(-300).timeIntervalSinceNow),repeats:false)
                    do{try await UNUserNotificationCenter.current().add(.init(identifier:"mewpon-meeting-"+(event.eventIdentifier ?? UUID().uuidString),content:content,trigger:trigger))}catch{status=error.localizedDescription}
                }
            }else{status="Calendar not authorized; no calendar data was read"}
        }
        if preferences.shouldBrief(now:now,lastDay:lastDay) {
            if calendar.canRead{calendar.refresh()}
            let pending=reminders.items.filter{!$0.completed && $0.due<now.addingTimeInterval(86400)}
            let today=calendar.canRead ? calendar.events.filter{Calendar.current.isDate($0.startDate,inSameDayAs:now)}:[]
            let summary="Local reminders due by tomorrow: "+String(pending.count)+". "+(calendar.canRead ? "Calendar events today: "+String(today.count)+". "+today.prefix(2).map{($0.title ?? "Untitled")+" at "+$0.startDate.formatted(date:.omitted,time:.shortened)}.joined(separator:"; "):"Calendar access is off.")
            guard !Task.isCancelled,!preferences.paused else{return}
            let content=UNMutableNotificationContent();content.title="Mewpon daily briefing";content.body=String(summary.prefix(1000))
            do{
                try await UNUserNotificationCenter.current().add(.init(identifier:"mewpon-daily-brief",content:content,trigger:UNTimeIntervalNotificationTrigger(timeInterval:1,repeats:false)))
                lastDay=ProactivePreferences.dayKey(now);UserDefaults.standard.set(lastDay,forKey:"lastDailyBriefV7");status="Daily briefing scheduled from actual local data"
            }catch{status=error.localizedDescription}
        }else if status.hasPrefix("Off") || status.hasPrefix("Paused") {status="Active while Mewpon runs · no screen or microphone monitoring"}
    }
}
struct ProactiveSettings:View {
    @ObservedObject var assistant:ProactiveAssistant
    @ObservedObject var reminders:ReminderLibrary
    var body:some View {
        Section("Opt-in personal assistance") {
            Toggle("Upcoming calendar notifications · 5 minutes before",isOn:$assistant.preferences.meetingAlerts)
            Toggle("Daily local briefing while Mewpon is running",isOn:$assistant.preferences.dailyBriefing)
            HStack{Stepper("Hour: "+String(assistant.preferences.hour),value:$assistant.preferences.hour,in:0...23);Stepper("Minute: "+String(assistant.preferences.minute),value:$assistant.preferences.minute,in:0...59)}
            Toggle("Pause all proactive monitoring",isOn:$assistant.preferences.paused)
            if !reminders.notificationsEnabled{Button("Enable notifications…"){Task{await reminders.enableNotifications();assistant.start()}}}
            Text(assistant.status).font(.caption)
            Text("Off by default. Reads only already authorized Calendar and local reminders when enabled. Upcoming alerts refresh every five minutes; briefings are generated at the selected local minute while the app is running. Quit stops monitoring. No screen, microphone or new account access.").font(.caption).foregroundStyle(.secondary)
        }
    }
}
