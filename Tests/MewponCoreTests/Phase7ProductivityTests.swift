import XCTest
import CryptoKit
@testable import MewponCore
@testable import MewponDesktop

final class Phase7ProductivityTests:XCTestCase {
    func testReminderTimesAndAmbiguity() throws {
        guard case .deterministic(.tool(let call))=FastIntentRouter.classify("Remind me to study DSA tomorrow at 8 PM") else{return XCTFail("Expected native reminder")}
        XCTAssertEqual(call.function.name,"local_reminders")
        XCTAssertEqual(call.function.arguments["title"],.string("study dsa"))
        let date=try XCTUnwrap(ISO8601DateFormatter().date(from:call.function.arguments["when"]!.string!))
        XCTAssertTrue(Calendar.current.isDateInTomorrow(date))
        XCTAssertEqual(Calendar.current.component(.hour,from:date),20)
        XCTAssertEqual(Calendar.current.component(.minute,from:date),0)
        guard case .needsClarification=FastIntentRouter.classify("Remind me to submit my assignment tomorrow") else{return XCTFail("A missing time must be clarified")}
        guard case .needsClarification=FastIntentRouter.classify("Remind me to study tomorrow at 25 PM") else{return XCTFail("Invalid time")}
    }
    func testCalendarRecurrencePreservesLocalHourAcrossDaylightSaving() throws {
        var calendar=Calendar(identifier:.gregorian);calendar.timeZone=TimeZone(identifier:"America/New_York")!
        let start=try XCTUnwrap(calendar.date(from:DateComponents(year:2026,month:3,day:7,hour:8)))
        let reminder=LocalReminder(title:"Morning",due:start,recurrence:"daily")
        let dates=reminder.dates(after:start.addingTimeInterval(-1),count:3,calendar:calendar)
        XCTAssertEqual(dates.count,3)
        XCTAssertTrue(dates.allSatisfy{calendar.component(.hour,from:$0)==8})
        XCTAssertEqual(dates[1].timeIntervalSince(dates[0]),23*3600,accuracy:0.1)
    }
    @MainActor func testEncryptedRemindersSurviveReloadAndCompleteWithoutPermissions() async throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:folder)}
        let storage=PrivateLibrary(root:folder,key:SymmetricKey(size:.bits256))
        let library=ReminderLibrary(storage:storage,notificationsEnabled:false)
        library.notificationsEnabled=false
        let due=Date().addingTimeInterval(3600)
        let item=try await library.add(title:"Private reminder",due:due,recurrence:"none")
        _ = try await library.add(title:"Private reminder",due:due,recurrence:"none")
        XCTAssertEqual(library.items.count,1)
        let loaded=ReminderLibrary(storage:storage,notificationsEnabled:false)
        XCTAssertEqual(loaded.items.first?.title,"Private reminder")
        try await loaded.complete(item.id)
        XCTAssertTrue(loaded.items.first?.completed==true)
        do{_ = try await library.add(title:"Past",due:.distantPast,recurrence:"none");XCTFail("Past reminder") }catch{}
    }
}
