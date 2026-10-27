import XCTest
import AppKit
import AVFoundation
@testable import MewponCore
@testable import MewponDesktop

final class Phase7VoiceTests:XCTestCase {
    func testSilentMediaIsRejectedBeforeModelInference() async throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false)
        defer{try? FileManager.default.removeItem(at:folder)}
        let format=AVAudioFormat(standardFormatWithSampleRate:16000,channels:1)!
        let buffer=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:16000)!;buffer.frameLength=16000
        for i in 0..<16000{buffer.floatChannelData![0][i]=0}
        let source=folder.appendingPathComponent("silence.wav"),output=folder.appendingPathComponent("converted.wav")
        do{let file=try AVAudioFile(forWriting:source,settings:format.settings);try file.write(from:buffer)}
        let audible=try await SpeechFiles.convert(source,to:output)
        XCTAssertFalse(audible)
        XCTAssertGreaterThan(try AVAudioFile(forReading:output).length,0)
    }
    func testEndpointAndWakePhraseNeverTreatOrdinaryConversationAsCommands() {
        var endpoint=VoiceEndpoint()
        for _ in 0..<30{XCTAssertFalse(endpoint.update(rms:0.001,duration:0.05))}
        XCTAssertFalse(endpoint.update(rms:0.08,duration:0.2))
        var ended=false
        for _ in 0..<21{ended=endpoint.update(rms:0.001,duration:0.05)}
        XCTAssertTrue(ended)
        XCTAssertEqual(VoiceEndpoint.wakeCommand("Hey Mewpon open Safari"),"open safari")
        XCTAssertNil(VoiceEndpoint.wakeCommand("We talked about hey Mewpon yesterday"))
        XCTAssertNil(VoiceEndpoint.wakeCommand("Open Safari"))
        XCTAssertEqual(FastIntentRouter.classify("Turn the volume down"),.deterministic(.tool(.init(name:"output_volume",arguments:["level":.string("down")]))))
    }
    func testExportsKeepTimestampsAndUnknownSpeakerIdentity() {
        let s=TranscriptSegment(start:1.23,end:4.56,text:"Backend is ready.")
        XCTAssertEqual(s.label,"Speaker unknown")
        XCTAssertTrue(TranscriptExport.srt([s]).contains("00:00:01,230 --> 00:00:04,560"))
        XCTAssertTrue(TranscriptExport.text([s]).contains("Speaker unknown"))
    }
    @MainActor func testInstalledOfflineSpeechProducesRealAudioAndWhisperTranscription() async throws {
        guard ProcessInfo.processInfo.environment["MEWPON_VOICE_TEST"]=="1" else{throw XCTSkip("Opt-in real offline voice benchmark")}
        _ = NSApplication.shared
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let out=root.appendingPathComponent("Verification/Phase7")
        let speech=LocalSpeech();speech.options.voiceID="com.apple.voice.super-compact.en-IN.Rishi"
        let wave=out.appendingPathComponent("voice-command.wav")
        if FileManager.default.fileExists(atPath:wave.path){try FileManager.default.removeItem(at:wave)}
        let start=ContinuousClock.now
        _ = try await withDeadline(seconds:45){try await speech.render("Change to dark mode.",to:wave)}
        let synthesis=elapsedMilliseconds(since:start)
        let file=try AVAudioFile(forReading:wave)
        XCTAssertGreaterThan(file.length,1000)
        let duration=Double(file.length)/file.processingFormat.sampleRate
        let t=ContinuousClock.now
        let segments=try await WhisperTranscriber.shared.transcribe(wave)
        let recognition=elapsedMilliseconds(since:t)
        let text=segments.map { $0.text }.joined(separator:" ")
        XCTAssertTrue(text.lowercased().contains("dark mode"),text)
        let report:[String:Any]=["engine":"whisper.cpp multilingual base","synthesis_ms":synthesis,"recognition_ms":recognition,"audio_seconds":duration,"recognition_realtime_factor":recognition/1000/duration,"transcript":text,"speaker_identification":"not performed","note":"Synthetic Indian English fixture; not an accuracy benchmark on real human speech." ]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("voice-benchmark.json"))
        speech.stop()
    }
    @MainActor func testHindiFixtureThroughInstalledVoiceAndLocalWhisper() async throws {
        guard ProcessInfo.processInfo.environment["MEWPON_HINDI_TEST"]=="1" else{throw XCTSkip("Opt-in Hindi fixture; no human accuracy claim")}
        guard let voice=LocalSpeech.voices.first(where:{$0.language.hasPrefix("hi")}) else{throw XCTSkip("No installed Hindi voice; no download performed")}
        _ = NSApplication.shared
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Verification/Phase7")
        let speech=LocalSpeech();speech.options.voiceID=voice.identifier
        let text="नमस्ते, आज मौसम अच्छा है।",wave=root.appendingPathComponent("hindi-command.wav")
        if FileManager.default.fileExists(atPath:wave.path){try FileManager.default.removeItem(at:wave)}
        _ = try await speech.render(text,to:wave)
        let start=ContinuousClock.now
        let segments=try await WhisperTranscriber.shared.transcribe(wave,language:"hi")
        let transcript=segments.map{$0.text}.joined(separator:" ")
        XCTAssertFalse(transcript.isEmpty)
        let report:[String:Any]=["fixture":text,"transcript":transcript,"recognition_ms":elapsedMilliseconds(since:start),"voice":voice.name,"engine":"whisper.cpp multilingual base","note":"Single synthetic Hindi fixture; not human-speech accuracy or noise tolerance."]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("hindi-fixture.json"))
        speech.stop()
    }
}
