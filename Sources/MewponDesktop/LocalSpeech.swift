import AppKit
import AVFoundation
import Speech
import MewponCore

struct SpeechOptions: Codable, Equatable {
    var voiceID = "com.apple.voice.super-compact.en-IN.Rishi"
    var rate: Float = 0.48
    var pitch: Float = 1
    var volume: Float = 0.8
    func utterance(_ text:String) throws -> AVSpeechUtterance {
        guard !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,text.count<=12000,(0.2...0.65).contains(rate),(0.5...2).contains(pitch),(0...1).contains(volume),let voice=AVSpeechSynthesisVoice(identifier:voiceID) else { throw MewponError.invalid("Choose an installed voice, valid voice controls, and 1–12000 characters.") }
        let u=AVSpeechUtterance(string:text);u.voice=voice;u.rate=rate;u.pitchMultiplier=pitch;u.volume=volume;return u
    }
}
@MainActor final class LocalSpeech: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var speaking=false
    @Published private(set) var generating=false
    @Published var issue:String?
    @Published var options:SpeechOptions {
        didSet {if let data=try? JSONEncoder().encode(options){UserDefaults.standard.set(data,forKey:"speechOptionsV7")}}
    }
    var amplitude:((Double)->Void)?
    private let synthesizer=AVSpeechSynthesizer()
    private var continuation:CheckedContinuation<URL,Error>?
    private var renderID=UUID()
    private var file:AVAudioFile?
    private var player:AVAudioPlayer?
    private var meter:Task<Void,Never>?
    private var speechTask:Task<Void,Never>?
    private var temporary:URL?
    private var renderingURL:URL?
    override init() {
        options=UserDefaults.standard.data(forKey:"speechOptionsV7").flatMap{try? JSONDecoder().decode(SpeechOptions.self,from:$0)} ?? SpeechOptions()
        super.init()
        refreshVoice()
    }
    func refreshVoice() {
        let installed=Self.voices
        if !installed.contains(where:{$0.identifier==options.voiceID}),let fallback=installed.first(where:{$0.language=="en-IN"}) ?? installed.first(where:{$0.language=="en-US"}) ?? installed.first { options.voiceID=fallback.identifier }
    }
    static var voices:[AVSpeechSynthesisVoice] { AVSpeechSynthesisVoice.speechVoices().sorted { ($0.language,$0.name)<($1.language,$1.name) } }
    func render(_ text:String,to url:URL) async throws -> URL {
        guard !generating else{throw MewponError.unavailable("Stop the current voice generation first.")}
        try Task.checkCancellation()
        refreshVoice();issue=nil
        let utterance=try options.utterance(text)
        guard !FileManager.default.fileExists(atPath:url.path) else{throw MewponError.invalid("Destination exists. Choose a new filename; no audio was overwritten.")}
        let id=UUID();renderID=id;generating=true;file=nil;renderingURL=url
        let start=ContinuousClock.now
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation=continuation
                synthesizer.write(utterance) { [weak self] buffer in
                    guard let pcm=buffer as? AVAudioPCMBuffer else{return}
                    Task { @MainActor in
                        guard let self,self.renderID==id,self.continuation != nil else{return}
                        do {
                            if pcm.frameLength==0 {
                                self.file=nil;self.generating=false;self.renderingURL=nil
                                let pending=self.continuation;self.continuation=nil
                                guard FileManager.default.fileExists(atPath:url.path) else{pending?.resume(throwing:MewponError.unavailable("The installed voice returned no audio."));return}
                                await PerformanceProfiler.shared.record("voice.synthesis",since:start)
                                pending?.resume(returning:url);return
                            }
                            if self.file==nil { self.file=try AVAudioFile(forWriting:url,settings:pcm.format.settings);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path) }
                            try self.file?.write(from:pcm)
                        } catch { self.stop(); self.issue=error.localizedDescription }
                    }
                }
            }
        } onCancel: { Task { @MainActor in if self.renderID==id {self.stop()} } }
    }
    func say(_ text:String) {
        stop()
        let url=FileManager.default.temporaryDirectory.appendingPathComponent("Mewpon-voice-"+UUID().uuidString+".wav")
        temporary=url
        speechTask=Task {
            do {
                try Task.checkCancellation()
                _ = try await render(text,to:url)
                guard temporary==url else{return}
                try play(url)
            } catch {if !(error is CancellationError){issue=error.localizedDescription};try? FileManager.default.removeItem(at:url)}
        }
    }
    func play(_ url:URL) throws {
        player=try AVAudioPlayer(contentsOf:url);player?.delegate=self;player?.isMeteringEnabled=true
        guard player?.play()==true else{throw MewponError.unavailable("Audio playback could not start.")}
        speaking=true
        meter=Task { [weak self] in
            while let self,self.speaking,let player=self.player {
                player.updateMeters()
                let level=pow(10,Double(player.averagePower(forChannel:0))/20)
                self.amplitude?(min(1,max(0,(level-0.008)*7)))
                do{try await Task.sleep(for:.milliseconds(50))}catch{break}
            }
        }
    }
    func stop() {
        renderID=UUID();speechTask?.cancel();speechTask=nil;_ = synthesizer.stopSpeaking(at:.immediate)
        let pending=continuation;continuation=nil;pending?.resume(throwing:CancellationError())
        file=nil;generating=false;player?.stop();player=nil;speaking=false;meter?.cancel();meter=nil;amplitude?(-1)
        if let renderingURL{try? FileManager.default.removeItem(at:renderingURL)};renderingURL=nil
        if let temporary{try? FileManager.default.removeItem(at:temporary)};temporary=nil
    }
    nonisolated func audioPlayerDidFinishPlaying(_ player:AVAudioPlayer,successfully flag:Bool) { Task { @MainActor in self.stop() } }
}

struct SpeechFiles {
    static func model(for language:String)->URL? {
        if let path=UserDefaults.standard.string(forKey:"whisperModelPath"),FileManager.default.isReadableFile(atPath:path){return URL(fileURLWithPath:path)}
        if language=="hi" {
            let bundled=Bundle.main.resourceURL?.appendingPathComponent("Speech/ggml-small.bin")
            #if DEBUG
            let development:URL?=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("LocalModels/ggml-small.bin")
            #else
            let development:URL?=nil
            #endif
            if let small=[bundled,development].compactMap({$0}).first(where:{FileManager.default.isReadableFile(atPath:$0.path)}){return small}
        }
        return model
    }
    static var model:URL? {
        let bundled=Bundle.main.resourceURL?.appendingPathComponent("Speech/ggml-base.bin")
        let selected=UserDefaults.standard.string(forKey:"whisperModelPath").map{URL(fileURLWithPath:$0)}
        #if DEBUG
        let development=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("LocalModels/ggml-base.bin")
        #else
        let development:URL?=nil
        #endif
        return [selected,bundled,development].compactMap{$0}.first{FileManager.default.isReadableFile(atPath:$0.path)}
    }
    static var executable:URL? {
        let bundled=Bundle.main.resourceURL?.appendingPathComponent("Speech/whisper-cli")
        return [bundled,URL(fileURLWithPath:"/opt/homebrew/bin/whisper-cli"),URL(fileURLWithPath:"/usr/local/bin/whisper-cli")].compactMap{$0}.first{FileManager.default.isExecutableFile(atPath:$0.path)}
    }
    static func selectModel() {
        let picker=NSOpenPanel();picker.allowedContentTypes=[.data];picker.message="Choose a locally installed whisper.cpp GGML model. No model download or cloud fallback."
        if picker.runModal() == .OK,let url=picker.url{UserDefaults.standard.set(url.path,forKey:"whisperModelPath")}
    }
    /// Native audio/video decode into bounded 16 kHz mono PCM; no shell or ffmpeg.
    @discardableResult static func convert(_ input:URL,to output:URL) async throws ->Bool {
        let asset=AVURLAsset(url:input)
        guard let track=try await asset.loadTracks(withMediaType:.audio).first else{throw MewponError.invalid("This file contains no supported audio track.")}
        let reader=try AVAssetReader(asset:asset)
        let settings:[String:Any]=[AVFormatIDKey:kAudioFormatLinearPCM,AVSampleRateKey:16000,AVNumberOfChannelsKey:1,AVLinearPCMBitDepthKey:16,AVLinearPCMIsFloatKey:false,AVLinearPCMIsBigEndianKey:false,AVLinearPCMIsNonInterleaved:false]
        let source=AVAssetReaderTrackOutput(track:track,outputSettings:settings);source.alwaysCopiesSampleData=false
        reader.add(source)
        guard reader.startReading() else{throw reader.error ?? MewponError.invalid("Audio decoder could not start.")}
        let format=AVAudioFormat(commonFormat:.pcmFormatInt16,sampleRate:16000,channels:1,interleaved:true)!
        let file=try AVAudioFile(forWriting:output,settings:settings,commonFormat:.pcmFormatInt16,interleaved:true)
        var total=0,audibleFrames=0
        while let sample=source.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block=CMSampleBufferGetDataBuffer(sample) else{continue}
            let count=CMBlockBufferGetDataLength(block);total += count
            guard total<=230_400_000 else{reader.cancelReading();throw MewponError.invalid("Import is limited to two hours of audio. Split this recording first.")}
            guard let pcm=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:AVAudioFrameCount(count/2)),let pointer=pcm.int16ChannelData?[0] else{throw MewponError.invalid("Unsupported PCM audio format.")}
            pcm.frameLength=AVAudioFrameCount(count/2)
            guard CMBlockBufferCopyDataBytes(block,atOffset:0,dataLength:count,destination:pointer)==noErr else{throw MewponError.invalid("Audio decoding failed.")}
            let frames=count/2
            if frames>0 {
                var energy=0.0
                for i in 0..<frames{let sample=Double(pointer[i])/32768;energy += sample*sample}
                if sqrt(energy/Double(frames))>0.002{audibleFrames += frames}
            }
            try file.write(from:pcm)
        }
        if reader.status == .failed {throw reader.error ?? MewponError.invalid("Audio decoding failed.")}
        return audibleFrames>=2400
    }
}
actor WhisperTranscriber {
    static let shared=WhisperTranscriber()
    private var running=false
    func transcribe(_ input:URL,language:String="en") async throws -> [TranscriptSegment] {
        guard !running else{throw MewponError.unavailable("A transcription is already running.")}
        guard let executable=SpeechFiles.executable,let model=SpeechFiles.model(for:language) else{throw MewponError.unavailable("The local whisper.cpp engine/model is not installed. Choose a local model in Voice settings.")}
        guard ["en","hi","auto"].contains(language) else{throw MewponError.invalid("Choose English, Hindi, or automatic language detection.")}
        let lease=try await InferenceScheduler.shared.begin();running=true
        defer{running=false;Task{await InferenceScheduler.shared.end(lease)}}
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("Mewpon-ASR-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        defer{try? FileManager.default.removeItem(at:root)}
        let wave=root.appendingPathComponent("input.wav"),prefix=root.appendingPathComponent("transcript")
        // An energy gate suppresses digital silence; it does not identify music or prove speech accuracy.
        guard try await SpeechFiles.convert(input,to:wave) else{return []}
        let process=Process();process.executableURL=executable
        process.arguments=["-m",model.path,"-f",wave.path,"-l",language,"-t","4","-bs","1","-bo","1","-oj","-of",prefix.path,"-np"]
        if language=="hi" {
            process.arguments=["-m",model.path,"-f",wave.path,"-l","hi","-t","4","-bs","5","-bo","5","--prompt","यह हिंदी भाषा की देवनागरी लिपि में बातचीत की प्रतिलिपि है।","-oj","-of",prefix.path,"-np"]
        }
        process.environment=["PATH":"/usr/bin:/bin","HOME":NSHomeDirectory(),"GGML_METAL_PATH_RESOURCES":executable.deletingLastPathComponent().appendingPathComponent("metal").path]
        let bundledPlugins=executable.deletingLastPathComponent().appendingPathComponent("lib")
        if FileManager.default.fileExists(atPath:bundledPlugins.path){process.currentDirectoryURL=bundledPlugins}
        process.standardInput=FileHandle.nullDevice;process.standardOutput=FileHandle.nullDevice;process.standardError=FileHandle.nullDevice
        let start=ContinuousClock.now
        try process.run()
        return try await withTaskCancellationHandler {
            while process.isRunning {
                do{try await Task.sleep(for:.milliseconds(100))}catch{if process.isRunning{process.terminate()};throw error}
                if elapsedMilliseconds(since:start)>600_000 {process.terminate();throw MewponError.timeout}
            }
            try Task.checkCancellation()
            guard process.terminationStatus==0 else{throw MewponError.unavailable("Local transcription exited with status \(process.terminationStatus). No transcript was invented.")}
            let data=try Data(contentsOf:prefix.appendingPathExtension("json"))
            guard data.count<=16_000_000 else{throw MewponError.invalid("Transcript is too large.")}
            let json=try JSONSerialization.jsonObject(with:data) as? [String:Any]
            let segments=(json?["transcription"] as? [[String:Any]] ?? []).compactMap{row -> TranscriptSegment? in
                guard let text=row["text"] as? String,let offsets=row["offsets"] as? [String:Double],let start=offsets["from"],let end=offsets["to"],!text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else{return nil}
                return TranscriptSegment(start:start/1000,end:end/1000,text:text.trimmingCharacters(in:.whitespacesAndNewlines))
            }
            await PerformanceProfiler.shared.record("voice.whisper_transcription",since:start)
            return segments
        } onCancel: {if process.isRunning{process.terminate()}}
    }
}
