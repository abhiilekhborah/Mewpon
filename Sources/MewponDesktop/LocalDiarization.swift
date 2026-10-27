import Foundation
import CryptoKit
import AVFoundation
import MewponCore

struct DiarizationFiles {
    static var root:URL? {
        let bundle=Bundle.main.resourceURL?.appendingPathComponent("Diarization")
        #if DEBUG
        let development:URL?=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build/Mewpon.app/Contents/Resources/Diarization")
        #else
        let development:URL?=nil
        #endif
        return [bundle,development].compactMap{$0}.first {root in FileManager.default.isExecutableFile(atPath:root.appendingPathComponent("mewpon-diarizer").path) && ["segmentation.onnx","embedding.onnx"].allSatisfy{FileManager.default.isReadableFile(atPath:root.appendingPathComponent($0).path)}}
    }
}
actor LocalDiarizer {
    static let shared=LocalDiarizer()
    func process(_ input:URL,knownSpeakers:Int=0) async throws ->[SpeakerTurn] {
        guard (0...12).contains(knownSpeakers),let backend=DiarizationFiles.root else{throw MewponError.unavailable("The verified local diarization runtime/models are not installed, or the speaker count is invalid.")}
        let lease=try await InferenceScheduler.shared.begin();defer{Task{await InferenceScheduler.shared.end(lease)}}
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("Mewpon-diarization-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]);defer{try? FileManager.default.removeItem(at:root)}
        let wave=root.appendingPathComponent("input.wav"),output=root.appendingPathComponent("turns.json")
        guard try await SpeechFiles.convert(input,to:wave) else{return []}
        let process=Process();process.executableURL=backend.appendingPathComponent("mewpon-diarizer")
        process.arguments=[wave.path,backend.appendingPathComponent("segmentation.onnx").path,backend.appendingPathComponent("embedding.onnx").path,output.path,String(knownSpeakers)]
        process.environment=["PATH":"/usr/bin:/bin"];process.standardInput=FileHandle.nullDevice;process.standardOutput=FileHandle.nullDevice;process.standardError=FileHandle.nullDevice
        let start=ContinuousClock.now;try process.run()
        return try await withTaskCancellationHandler {
            while process.isRunning {
                do{try await Task.sleep(for:.milliseconds(100))}catch{if process.isRunning{process.terminate()};throw error}
                if elapsedMilliseconds(since:start)>900_000{process.terminate();throw MewponError.timeout}
            }
            try Task.checkCancellation()
            guard process.terminationStatus==0 else{throw MewponError.unavailable("Local diarization exited with status \(process.terminationStatus). No speaker labels were applied.")}
            guard (try output.resourceValues(forKeys:[.fileSizeKey])).fileSize ?? Int.max<=10_000_000 else{throw MewponError.invalid("Diarization output exceeds its limit.")}
            struct Result:Decodable{let turns:[SpeakerTurn]}
            let result=try JSONDecoder().decode(Result.self,from:Data(contentsOf:output))
            guard result.turns.count<=50000,result.turns.allSatisfy({$0.valid}) else{throw MewponError.invalid("Invalid diarization timestamps or confidence scores. No speaker identity was inferred.")}
            await PerformanceProfiler.shared.record("meeting.diarization",since:start)
            return result.turns
        }onCancel:{if process.isRunning{process.terminate()}}
    }
}

struct MeetingAudio {
    static func fingerprint(_ url:URL) throws ->String {
        let handle=try FileHandle(forReadingFrom:url);defer{try? handle.close()}
        var hash=SHA256()
        while let data=try handle.read(upToCount:1024*1024),!data.isEmpty{try Task.checkCancellation();hash.update(data:data)}
        return hash.finalize().map{String(format:"%02x",$0)}.joined()
    }
    static func concatenate(_ ids:[UUID],storage:PrivateLibrary,to destination:URL) async throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("Mewpon-audio-join-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]);defer{try? FileManager.default.removeItem(at:folder)}
        let settings:[String:Any]=[AVFormatIDKey:kAudioFormatLinearPCM,AVSampleRateKey:16000,AVNumberOfChannelsKey:1,AVLinearPCMBitDepthKey:16,AVLinearPCMIsFloatKey:false,AVLinearPCMIsBigEndianKey:false]
        let output=try AVAudioFile(forWriting:destination,settings:settings,commonFormat:.pcmFormatInt16,interleaved:true)
        var total:AVAudioFramePosition=0
        for id in ids {
            try Task.checkCancellation()
            let caf=folder.appendingPathComponent(id.uuidString+".caf"),wave=folder.appendingPathComponent(id.uuidString+".wav")
            try storage.loadData(id:id,kind:"audio").write(to:caf)
            try await SpeechFiles.convert(caf,to:wave)
            let file=try AVAudioFile(forReading:wave,commonFormat:.pcmFormatInt16,interleaved:true)
            guard total+file.length<=115200000 else{throw MewponError.invalid("Combined recording exceeds two hours.")};total += file.length
            guard let buffer=AVAudioPCMBuffer(pcmFormat:file.processingFormat,frameCapacity:16000) else{throw MewponError.invalid("Audio buffer unavailable.")}
            while file.framePosition<file.length{try Task.checkCancellation();try file.read(into:buffer);try output.write(from:buffer)}
            try FileManager.default.removeItem(at:caf);try FileManager.default.removeItem(at:wave)
        }
    }
}
