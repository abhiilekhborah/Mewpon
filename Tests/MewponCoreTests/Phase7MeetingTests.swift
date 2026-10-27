import XCTest
import CryptoKit
import PDFKit
import AVFoundation
import CoreMedia
@testable import MewponCore
@testable import MewponDesktop

final class Phase7MeetingTests:XCTestCase {
    func testRetentionOnlySelectsOldInactiveEncryptedMeetings() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let storage=PrivateLibrary(root:root,key:SymmetricKey(size:.bits256)),old=MeetingDocument(title:"Old fixture",source:"Test"),recent=MeetingDocument(title:"Recent fixture",source:"Test")
        try storage.save(old,id:old.id);try storage.save(recent,id:recent.id)
        let file=root.appendingPathComponent("meeting-"+old.id.uuidString+".sealed")
        try FileManager.default.setAttributes([.modificationDate:Date.now.addingTimeInterval(-100*86400)],ofItemAtPath:file.path)
        XCTAssertEqual(storage.retentionCandidates(days:90),[old.id])
        XCTAssertTrue(storage.retentionCandidates(days:90,excluding:old.id).isEmpty)
        XCTAssertTrue(storage.retentionCandidates(days:0).isEmpty)
    }
    @MainActor func testGroundedActionsCanBeTrackedAndCompletedWithoutInventedDeadlines() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let library=MeetingLibrary(storage:PrivateLibrary(root:root,key:SymmetricKey(size:.bits256)))
        var doc=MeetingDocument(title:"Follow-up fixture",source:"Test")
        let segment=TranscriptSegment(start:10,end:15,text:"Alex will submit the report on Friday.")
        doc.segments=[segment];library.current=doc
        let action=GroundedExcerpt(segmentID:segment.id,category:"action",quote:segment.text,owner:"Alex",deadline:"Friday")
        library.trackAction(action);library.trackAction(action)
        XCTAssertEqual(library.current?.notes.count,1)
        let note=try XCTUnwrap(library.current?.notes.first)
        XCTAssertEqual(note.timestamp,10);XCTAssertEqual(note.text,segment.text)
        library.completeNote(note.id,true)
        XCTAssertTrue(library.current?.notes.first?.completed==true)
    }
    func testSpeakerAlignmentKeepsUncertainMixedAndManualLinesUnknownOrUnchanged() {
        let turns=[SpeakerTurn(start:0,end:4,speaker:0,confidence:0.8),SpeakerTurn(start:4,end:8,speaker:1,confidence:0.9),SpeakerTurn(start:8,end:12,speaker:2,confidence:0.3)]
        let segments=[TranscriptSegment(start:0.1,end:3.9,text:"First voice"),TranscriptSegment(start:4.1,end:7.9,text:"Second voice"),TranscriptSegment(start:8.1,end:11.9,text:"Uncertain voice"),TranscriptSegment(start:3,end:5,text:"Mixed voices"),TranscriptSegment(start:0,end:4,text:"Manual assignment",speaker:"Alex")]
        let result=SpeakerAlignment.apply(turns,to:segments)
        XCTAssertEqual(result[0].speaker,"Speaker 1");XCTAssertEqual(result[1].speaker,"Speaker 2")
        XCTAssertEqual(result[0].speakerSource,"automatic")
        XCTAssertNil(result[2].speaker);XCTAssertNil(result[3].speaker);XCTAssertEqual(result[4].speaker,"Alex")
        var legacy=segments[4];legacy.speakerSource=nil
        XCTAssertEqual(SpeakerAlignment.apply(turns,to:[legacy]).first?.speaker,"Alex")
        XCTAssertFalse(SpeakerTurn(start:0,end:1,speaker:0,confidence:.nan).valid)
    }
    func testActualLocalDiarizationReturnsTimestampedClusters() async throws {
        guard ProcessInfo.processInfo.environment["MEWPON_DIARIZATION_TEST"]=="1" else{throw XCTSkip("Opt-in official four-speaker audio fixture")}
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let start=ContinuousClock.now
        let turns=try await LocalDiarizer.shared.process(root.appendingPathComponent("Verification/Phase7/diarization-four-speakers.wav"))
        XCTAssertFalse(turns.isEmpty);XCTAssertTrue(turns.allSatisfy{$0.valid})
        XCTAssertEqual(Set(turns.map{$0.speaker}).count,4)
        let high=try XCTUnwrap(turns.first(where:{$0.confidence>=0.6}))
        let label=SpeakerAlignment.apply(turns,to:[TranscriptSegment(start:high.start+0.01,end:high.end-0.01,text:"Controlled alignment fixture")]).first
        XCTAssertNotNil(label?.speaker)
        let report:[String:Any]=["elapsed_ms":elapsedMilliseconds(since:start),"audio_seconds":56.861,"speaker_clusters":Set(turns.map{$0.speaker}).count,"turn_count":turns.count,"high_confidence_turns":turns.filter{$0.confidence>=0.6}.count,"backend":"sherpa-onnx 2.0.0, pyannote INT8 segmentation, 3D-Speaker ERes2Net","known_speakers_supplied":false,"note":"Official upstream Chinese multi-speaker fixture; not a real meeting DER evaluation or speaker identity recognition."]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("Verification/Phase7/diarization-benchmark.json"))
    }
    func testLocalModelProducesOnlyVerifiedMeetingExcerpts() async throws {
        guard ProcessInfo.processInfo.environment["MEWPON_SUMMARY_TEST"]=="1" else{throw XCTSkip("Opt-in actual local-model summary")}
        var document=MeetingDocument(title:"Synthetic planning fixture",source:"Test fixture; no real meeting")
        document.segments=[.init(start:0,end:5,text:"We decided to use SQLite for the local backend."),.init(start:5,end:10,text:"Alex will submit the report on Friday."),.init(start:10,end:15,text:"The release date is still an open question.")]
        var configuration=ModelConfiguration();configuration.model="qwen3:4b-instruct";configuration.thinking = .disabled;configuration.temperature=0;configuration.maximumTokens=900
        let start=ContinuousClock.now
        let excerpts=try await MeetingSummarizer().summarize(document,configuration:configuration)
        XCTAssertFalse(excerpts.isEmpty)
        XCTAssertTrue(excerpts.allSatisfy{$0.validated(against:document.segments)})
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let report:[String:Any]=["elapsed_ms":elapsedMilliseconds(since:start),"model":configuration.model,"excerpt_count":excerpts.count,"quotes":excerpts.map{$0.quote},"note":"Synthetic fixture; validation proves verbatim grounding, not completeness or general accuracy."]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("Verification/Phase7/summary-benchmark.json"))
    }
    func testSlideChangeRejectsDuplicatesAndSmallCursorChanges() {
        let original=[UInt8](repeating:80,count:576)
        XCTAssertTrue(SlideChange.meaningful(previous:nil,current:original))
        XCTAssertFalse(SlideChange.meaningful(previous:original,current:original))
        var cursor=original;cursor[0]=255
        XCTAssertFalse(SlideChange.meaningful(previous:original,current:cursor))
        XCTAssertTrue(SlideChange.meaningful(previous:original,current:[UInt8](repeating:160,count:576)))
    }
    func testCapturedPCMIsSavedAndFinalChunkDeliveredBeforeStopReturns() async throws {
        let format=AVAudioFormat(standardFormatWithSampleRate:48000,channels:1)!
        let pcm=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:4800)!;pcm.frameLength=4800
        for i in 0..<4800{pcm.floatChannelData![0][i]=0.1}
        var block:CMBlockBuffer?
        XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(allocator:nil,memoryBlock:nil,blockLength:19200,blockAllocator:nil,customBlockSource:nil,offsetToData:0,dataLength:19200,flags:0,blockBufferOut:&block),noErr)
        let data=try XCTUnwrap(block)
        XCTAssertEqual(CMBlockBufferReplaceDataBytes(with:pcm.floatChannelData![0],blockBuffer:data,offsetIntoDestination:0,dataLength:19200),noErr)
        var sample:CMSampleBuffer?
        XCTAssertEqual(CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator:nil,dataBuffer:data,formatDescription:format.formatDescription,sampleCount:4800,presentationTimeStamp:.zero,packetDescriptions:nil,sampleBufferOut:&sample),noErr)
        let captured=try XCTUnwrap(sample)
        let delivered=expectation(description:"Final audio chunk delivered")
        let sink=MeetingCaptureSink(slides:false,chunk:{url in
            defer{try? FileManager.default.removeItem(at:url)}
            do{
                let file=try AVAudioFile(forReading:url);XCTAssertEqual(file.length,4800);XCTAssertEqual(file.processingFormat.sampleRate,48000)
                let read=try XCTUnwrap(AVAudioPCMBuffer(pcmFormat:file.processingFormat,frameCapacity:4800));try file.read(into:read)
                XCTAssertEqual(try XCTUnwrap(read.floatChannelData?[0][0]),0.1,accuracy:0.001)
            }catch{XCTFail(error.localizedDescription)}
            delivered.fulfill()
        },slide:{_,_ in XCTFail("Slides disabled")},failure:{XCTFail($0)})
        sink.queue.sync{sink.consume(captured,type:.audio)}
        await sink.finish()
        await fulfillment(of:[delivered],timeout:1)
    }
    func testBackgroundSearchFindsLexicalEvidence() async throws {
        let search=MeetingSearch()
        let segments=[TranscriptSegment(start:0,end:4,text:"The backend database uses SQLite."),TranscriptSegment(start:4,end:8,text:"Lunch will be at noon.")]
        let results=try await search.find("backend SQLite",in:segments)
        XCTAssertEqual(results.first?.id,segments[0].id)
    }
    func testPrivateLibraryEncryptsAndRejectsTampering() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("Mewpon-private-test-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let store=PrivateLibrary(root:root,key:SymmetricKey(size:.bits256))
        var meeting=MeetingDocument(title:"Controlled fixture",source:"Synthetic")
        meeting.segments=[.init(start:0,end:3,text:"Private fixture content never stored as plaintext.")]
        try store.save(meeting,id:meeting.id)
        let restored=try store.load(MeetingDocument.self,id:meeting.id)
        XCTAssertEqual(restored.segments,meeting.segments)
        let file=try XCTUnwrap(FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil).first)
        var bytes=try Data(contentsOf:file)
        XCTAssertNil(String(data:bytes,encoding:.utf8))
        bytes[bytes.count/2] ^= 1;try bytes.write(to:file)
        XCTAssertThrowsError(try store.load(MeetingDocument.self,id:meeting.id))
    }
    func testGroundedExcerptsRejectInventedOwnersAndQuotes() {
        let segment=TranscriptSegment(start:0,end:2,text:"Alex will submit the report on Friday.")
        XCTAssertTrue(GroundedExcerpt(segmentID:segment.id,category:"action",quote:segment.text,owner:"Alex",deadline:"Friday").validated(against:[segment]))
        XCTAssertFalse(GroundedExcerpt(segmentID:segment.id,category:"action",quote:segment.text,owner:"Jamie",deadline:"Friday").validated(against:[segment]))
        XCTAssertFalse(GroundedExcerpt(segmentID:segment.id,category:"action",quote:segment.text,owner:"Al",deadline:"day").validated(against:[segment]))
        XCTAssertFalse(GroundedExcerpt(segmentID:segment.id,category:"decision",quote:"We decided to use a cloud API.").validated(against:[segment]))
        XCTAssertFalse(GroundedExcerpt(segmentID:UUID(),category:"action",quote:segment.text).validated(against:[segment]))
    }
    @MainActor func testTranscriptPDFPaginatesWithoutDroppingTheEnd() throws {
        let text=(0..<220).map{"Transcript line \($0): a controlled paragraph about project decisions, deadlines and local tools."}.joined(separator:"\n\n")+"\nFINAL TRANSCRIPT SENTINEL"
        let data=try MeetingPDF.data(text)
        let pdf=try XCTUnwrap(PDFDocument(data:data))
        XCTAssertGreaterThan(pdf.pageCount,1)
        XCTAssertTrue(pdf.string?.contains("FINAL TRANSCRIPT SENTINEL")==true)
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try data.write(to:root.appendingPathComponent("Verification/Phase7/transcript-export-fixture.pdf"))
    }
    @MainActor func testImportedAudioHasRealTranscriptAndEncryptedStorage() async throws {
        guard ProcessInfo.processInfo.environment["MEWPON_MEETING_TEST"]=="1" else{throw XCTSkip("Opt-in actual offline meeting import")}
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:folder)}
        let library=MeetingLibrary(storage:PrivateLibrary(root:folder,key:SymmetricKey(size:.bits256)))
        library.importFile(root.appendingPathComponent("Verification/Phase7/voice-command.wav"))
        for _ in 0..<600 where library.busy {try await Task.sleep(for:.milliseconds(100))}
        XCTAssertFalse(library.busy)
        XCTAssertNil(library.issue)
        XCTAssertTrue(library.current?.segments.first?.text.lowercased().contains("dark mode")==true)
        XCTAssertEqual(try library.storage.meetings().count,1)
    }
}
