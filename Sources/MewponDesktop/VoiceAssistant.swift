import AppKit
import AVFoundation
import Speech
import SwiftUI
import MewponCore

@MainActor final class VoiceAssistant: ObservableObject {
    @Published private(set) var listening=false
    @Published private(set) var transcribing=false
    @Published private(set) var partial=""
    @Published private(set) var level=0.0
    @Published private(set) var status="Microphone off"
    @Published var issue:String?
    @Published var localeID="en-IN"
    @Published var backend="apple"
    @Published private(set) var wakeEnabled=false
    @Published var speakReplies=false
    let speech=LocalSpeech()
    var onCommand:((String)->Void)?
    var onListening:((Bool)->Void)?
    var onPartial:((String)->Void)?
    var onRecordingFinished:((URL,String)->Void)?
    var canResumeWake:()->Bool = {true}
    private static var microphoneOwner:UUID?
    private var microphoneLease:UUID?
    private var engine:AVAudioEngine?
    private var request:SFSpeechAudioBufferRecognitionRequest?
    private var recognition:SFSpeechRecognitionTask?
    private var endpoint=VoiceEndpoint()
    private var watchdog:Task<Void,Never>?
    private var transcriptionTask:Task<Void,Never>?
    private var wakeRestart:Task<Void,Never>?
    private var generation=UUID()
    private var finishing=false
    private var wakeHeard=false
    private var output:AVAudioFile?
    private var audioURL:URL?
    private var recordOnly=false
    var microphoneStatus:AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for:.audio) }
    var speechStatus:SFSpeechRecognizerAuthorizationStatus {SFSpeechRecognizer.authorizationStatus()}
    func requestAccess() async {
        if microphoneStatus == .notDetermined {_ = await AVCaptureDevice.requestAccess(for:.audio)}
        if backend=="apple",speechStatus == .notDetermined {
            _ = await withCheckedContinuation { (c:CheckedContinuation<SFSpeechRecognizerAuthorizationStatus,Never>) in SFSpeechRecognizer.requestAuthorization {c.resume(returning:$0)} }
        }
        status="Microphone: \(microphoneStatus == .authorized ? "allowed":"not allowed") · Speech: \(speechStatus == .authorized ? "allowed":"not allowed")"
    }
    func setWake(_ enabled:Bool) {
        stop();wakeEnabled=enabled
        if enabled {
            guard backend=="apple" else{issue="Wake phrase requires the on-device streaming engine. Whisper file transcription remains available.";wakeEnabled=false;return}
            start(wake:true)
        }
    }
    func toggle() {listening ? finish():start()}
    func start(wake:Bool=false,recordOnly:Bool=false) {
        guard !listening,!transcribing else{return}
        guard Self.microphoneOwner==nil else{issue="Another Mewpon recording owns the microphone. Stop it first.";return}
        guard microphoneStatus == .authorized else{issue="Enable microphone access in Voice settings first.";wakeEnabled=false;return}
        speech.stop();issue=nil;partial="";finishing=false;wakeHeard=false;self.recordOnly=recordOnly;endpoint=VoiceEndpoint()
        let id=UUID();generation=id
        let engine=AVAudioEngine();let input=engine.inputNode
        let format=input.outputFormat(forBus:0)
        guard format.sampleRate>0,format.channelCount>0 else{issue="No microphone input is available.";wakeEnabled=false;return}
        var request:SFSpeechAudioBufferRecognitionRequest?
        if backend=="apple",!recordOnly {
            guard speechStatus == .authorized,let recognizer=SFSpeechRecognizer(locale:Locale(identifier:localeID)),recognizer.isAvailable,recognizer.supportsOnDeviceRecognition else{issue="On-device streaming speech is unavailable for this locale. No cloud fallback is used. Choose English/Indian English or Whisper.";wakeEnabled=false;return}
            let r=SFSpeechAudioBufferRecognitionRequest();r.requiresOnDeviceRecognition=true;r.shouldReportPartialResults=true;r.taskHint = .dictation;r.contextualStrings=["Hey Mewpon","Open Safari","VS Code","dark mode","volume"]
            request=r;self.request=r
            recognition=recognizer.recognitionTask(with:r) { [weak self] result,error in
                Task { @MainActor in
                    guard let self,self.generation==id else{return}
                    if let result {
                        let text=result.bestTranscription.formattedString
                        if wake && !self.wakeHeard {
                            guard let command=VoiceEndpoint.wakeCommand(text) else{return}
                            self.wakeHeard=true;self.partial=command
                        } else {self.partial=wake ? (VoiceEndpoint.wakeCommand(text) ?? text):text}
                        self.onPartial?(self.partial)
                        if result.isFinal {self.completeStreaming()}
                    }
                    if let error,!self.finishing {self.issue=error.localizedDescription;self.stop()}
                }
            }
        }
        // Optional audio lives only in a private temporary file until explicit
        // meeting save/import; wake listening never writes an audio file.
        if !wake {
            let url=FileManager.default.temporaryDirectory.appendingPathComponent("Mewpon-mic-"+UUID().uuidString+".caf")
            do {output=try AVAudioFile(forWriting:url,settings:format.settings);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path);audioURL=url}
            catch{issue=error.localizedDescription;stop();return}
        }
        Self.microphoneOwner=id;microphoneLease=id
        let writer=output
        input.installTap(onBus:0,bufferSize:2048,format:format) { [weak self] buffer,_ in
            request?.append(buffer)
            if let writer { do{try writer.write(from:buffer)}catch{Task { @MainActor in self?.issue="Microphone audio could not be written: "+error.localizedDescription;self?.stop() };return} }
            let n=Int(buffer.frameLength)
            var rms=0.0
            if let values=buffer.floatChannelData?[0],n>0 {for i in 0..<n{rms += Double(values[i]*values[i])};rms=sqrt(rms/Double(n))}
            let duration=Double(buffer.frameLength)/buffer.format.sampleRate
            Task { @MainActor in
                guard let self,self.generation==id,self.listening else{return}
                self.level=min(1,rms*12)
                let ended=self.endpoint.update(rms:rms,duration:duration)
                if ended && (!wake || self.wakeHeard),!recordOnly {self.finish()}
            }
        }
        self.engine=engine
        do {engine.prepare();try engine.start();listening=true;status=wake ? "Microphone on · waiting for Hey Mewpon":"Listening on this Mac…";onListening?(true)}
        catch{issue=error.localizedDescription;stop();return}
        watchdog=Task { [weak self] in
            do{try await Task.sleep(for:.seconds(wake ? 55:30));guard let self,self.generation==id else{return};if wake && !self.wakeHeard{self.rotateWake()}else if !recordOnly{self.finish()}}catch{}
        }
    }
    private func stopEngine() {
        if let engine {engine.inputNode.removeTap(onBus:0);engine.stop()}
        engine=nil;output=nil;if Self.microphoneOwner==microphoneLease{Self.microphoneOwner=nil};microphoneLease=nil;listening=false;level=0;watchdog?.cancel();watchdog=nil;onListening?(false)
    }
    func finish() {
        guard listening,!finishing else{return}
        if !recordOnly,!endpoint.heardSpeech {stop();issue="No speech was detected. Nothing executed.";return}
        finishing=true;stopEngine();request?.endAudio()
        if recordOnly {
            generation=UUID();recognition?.cancel();recognition=nil;request=nil;finishing=false
            if let url=audioURL {audioURL=nil;onRecordingFinished?(url,endpoint.heardSpeech ? "speech":"silence")}
            status="Microphone off";return
        }
        if backend=="apple" {
            watchdog=Task { [weak self] in do{try await Task.sleep(for:.milliseconds(700));self?.completeStreaming()}catch{} }
        } else {
            guard let url=audioURL else{stop();return};audioURL=nil;transcribing=true;status="Transcribing locally…"
            let id=generation
            transcriptionTask=Task { [weak self] in
                defer{try? FileManager.default.removeItem(at:url)}
                guard let self else{return}
                do {let segments=try await WhisperTranscriber.shared.transcribe(url,language:self.localeID.hasPrefix("hi") ? "hi":"en");try Task.checkCancellation();guard self.generation==id else{return};self.partial=segments.map(\.text).joined(separator:" ");self.transcribing=false;self.finishing=false;self.deliver()}
                catch {self.transcribing=false;self.issue=error.localizedDescription;self.stop()}
            }
        }
    }
    private func completeStreaming() {
        guard listening || finishing else{return}
        generation=UUID();stopEngine();recognition?.cancel();recognition=nil;request=nil;finishing=false
        if let url=audioURL{try? FileManager.default.removeItem(at:url)};audioURL=nil
        deliver()
    }
    private func deliver() {
        let text=partial.trimmingCharacters(in:.whitespacesAndNewlines)
        status="Microphone off"
        if !text.isEmpty {onCommand?(text)}
        if wakeEnabled {
            wakeRestart?.cancel()
            wakeRestart=Task { [weak self] in
                do {
                    try await Task.sleep(for:.seconds(1))
                    while let self,self.wakeEnabled {
                        try Task.checkCancellation()
                        if !self.speech.speaking,!self.speech.generating,self.canResumeWake(){self.start(wake:true);return}
                        try await Task.sleep(for:.milliseconds(250))
                    }
                }catch{}
            }
        }
    }
    private func rotateWake() {stopEngine();recognition?.cancel();recognition=nil;request=nil;finishing=false;start(wake:true)}
    func stop() {
        wakeRestart?.cancel();wakeRestart=nil
        wakeEnabled=false;generation=UUID();transcriptionTask?.cancel();transcriptionTask=nil;transcribing=false;stopEngine();recognition?.cancel();recognition=nil;request=nil;finishing=false
        if let url=audioURL{try? FileManager.default.removeItem(at:url)};audioURL=nil
        status="Microphone off";partial="";speech.stop()
    }
}
struct VoiceSettingsView:View {
    @ObservedObject var voice:VoiceAssistant
    var body:some View {
        Form {
            Section("Offline recognition") {
                Picker("Engine",selection:$voice.backend){Text("Apple · on-device streaming").tag("apple");Text("Whisper · offline utterances").tag("whisper")}.disabled(voice.listening)
                Picker("Language",selection:$voice.localeID){Text("Indian English").tag("en-IN");Text("English (US)").tag("en-US");Text("Hindi · Whisper only").tag("hi-IN")}.disabled(voice.listening)
                Text("Apple recognition explicitly requires on-device processing. Unsupported locales fail closed. Whisper uses only the installed local model; no audio upload.").font(.caption)
                Text("Whisper: \(SpeechFiles.executable == nil ? "not installed":"engine available") · \(SpeechFiles.model == nil ? "model needed":"model available")").font(.caption)
                Button("Choose local Whisper model…"){SpeechFiles.selectModel()}
                Button("Enable microphone and on-device speech…"){Task{await voice.requestAccess()}}
                Toggle("Listen for Hey Mewpon",isOn:Binding(get:{voice.wakeEnabled},set:{voice.setWake($0)}))
                Text("Wake listening is opt-in, ASR-based, and uses the microphone continuously while enabled. Audio is not saved. It is not a dedicated low-power keyword model; turn it off to release the microphone.").font(.caption)
            }
            Section("Voice interaction") {
                HStack{Button(voice.listening ? "Finish speaking":"Start voice command"){voice.toggle()};Button("Stop all voice"){voice.stop()}}
                Text(voice.status).foregroundStyle(voice.listening ? .orange:.secondary)
                ProgressView(value:voice.level).accessibilityLabel("Microphone level")
                if !voice.partial.isEmpty{Text(voice.partial).textSelection(.enabled)}
                Toggle("Speak completed assistant replies",isOn:$voice.speakReplies)
                if let issue=voice.issue{Text(issue).foregroundStyle(.orange)}
            }
        }.formStyle(.grouped)
    }
}
struct VoiceStudioView:View {
    @ObservedObject var speech:LocalSpeech
    @State private var text="Hello, I’m Mewpon. Everything you hear is generated on this Mac."
    @State private var message=""
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            HStack{Text("Voice Studio").font(.title2.bold());Spacer();Text("On this Mac").foregroundStyle(.secondary)}
            TextEditor(text:$text).font(.body).frame(minHeight:180).border(.secondary.opacity(0.2))
            Picker("Installed voice",selection:$speech.options.voiceID){ForEach(LocalSpeech.voices,id:\.identifier){v in Text(v.name+" · "+v.language).tag(v.identifier)}}
            HStack{Text("Rate");Slider(value:$speech.options.rate,in:0.2...0.65);Text("Pitch");Slider(value:$speech.options.pitch,in:0.5...2);Text("Volume");Slider(value:$speech.options.volume,in:0...1)}
            HStack {
                Button(speech.generating ? "Generating…":"Preview"){speech.say(text)}.disabled(speech.generating)
                Button("Stop immediately"){speech.stop()}
                Button("Export WAV…"){
                    let panel=NSSavePanel();panel.allowedContentTypes=[.wav];panel.nameFieldStringValue="Mewpon Voice.wav"
                    if panel.runModal() == .OK,let url=panel.url{Task{do{_ = try await speech.render(text,to:url);message="Saved locally: "+url.lastPathComponent}catch{message=error.localizedDescription}}}
                }.disabled(speech.generating)
                Spacer()
            }
            Text(speech.speaking ? "Speaking locally…":speech.generating ? "Generating audio locally…":"Ready · microphone not used").font(.caption).foregroundStyle(speech.speaking ? .orange:.secondary)
            Text("Installed macOS voices · adjustable rate, pitch and volume. Emotional voice styles and streamed synthesis are not claimed.").font(.caption).foregroundStyle(.secondary)
            if !message.isEmpty{Text(message).font(.caption).textSelection(.enabled)}
            if let issue=speech.issue{Text(issue).foregroundStyle(.orange)}
        }.padding(24).frame(minWidth:720,minHeight:440).onAppear{speech.refreshVoice()}
    }
}

struct VoiceCommandButton:View {
    @ObservedObject var voice:VoiceAssistant
    var body:some View {
        Button {if voice.microphoneStatus != .authorized || voice.backend=="apple" && voice.speechStatus != .authorized{AppCoordinator.shared?.showVoice()}else{voice.toggle()}} label:{Image(systemName:voice.listening ? "mic.fill":voice.transcribing ? "waveform":"mic").foregroundStyle(voice.listening ? .orange:.secondary)}
            .buttonStyle(.plain).help(voice.status).accessibilityLabel(voice.listening ? "Finish voice command · microphone active":"Start voice command")
            .overlay(alignment:.topTrailing){if voice.listening{Circle().fill(.orange).frame(width:5,height:5)}}
    }
}

struct VoiceOutputTool:AssistantTool {
    let spec=ToolSpec("voice_output","Speak supplied text with installed offline voices, or stop speech immediately. Never enables microphone or recording.",fields:["action":"speak, stop, or stop_all","text":"Text to speak, or none"],capability:.systemControl)
    func execute(arguments:[String:JSONValue]) async throws ->ToolResult {
        await MainActor.run {
            guard let voice=AppCoordinator.shared?.model.voice else{return ToolResult(false,"Voice service is unavailable.")}
            if arguments["action"]?.string=="stop_all"{AppCoordinator.shared?.stopVoice();return ToolResult(true,"Microphone activity and speech stopped.")}
            if arguments["action"]?.string=="stop"{voice.speech.stop();return ToolResult(true,"Speech stopped.")}
            guard arguments["action"]?.string=="speak" else{return ToolResult(false,"Unsupported speech action.")}
            voice.speech.say(arguments["text"]!.string!);return ToolResult(true,"Generating speech locally; playback begins when audio is ready.")
        }
    }
}
struct AssistantWorkspaceTool:AssistantTool {
    let spec=ToolSpec("assistant_workspace","Open a dedicated Mewpon voice, studio, meetings or productivity workspace.",fields:["workspace":"voice, studio, meetings, productivity"],capability:.launchApplication)
    func execute(arguments:[String:JSONValue]) async throws ->ToolResult {
        await MainActor.run {
            guard let coordinator=AppCoordinator.shared else{return ToolResult(false,"Workspace service unavailable.")}
            switch arguments["workspace"]?.string {case "voice":coordinator.showVoice();case "studio":coordinator.showVoiceStudio();case "meetings":coordinator.showMeetings();case "productivity":coordinator.showProductivity();default:return ToolResult(false,"Unknown workspace.")}
            return ToolResult(true,"Opened the requested Mewpon workspace.")
        }
    }
}
