import AppKit
import ScreenCaptureKit
import AVFoundation
import CoreImage
import MewponCore

/// Only receives the target explicitly selected in the macOS picker for this session.
@MainActor final class SystemMeetingCapture:NSObject,ObservableObject,SCContentSharingPickerObserver,SCStreamDelegate {
    @Published private(set) var active=false
    @Published private(set) var choosing=false
    @Published private(set) var ready=false
    @Published private(set) var targetDescription="No target selected"
    var onChunk:((URL)->Void)?
    var onSlide:((Data,Double)->Void)?
    var onFailure:((String)->Void)?
    private var selection:CheckedContinuation<SCContentFilter,Error>?
    private var stream:SCStream?
    private var sink:MeetingCaptureSink?
    private var starting:Task<Void,Never>?
    private var stopJob:Task<Void,Never>?
    func prepare(slides:Bool,expectedBundle:String?=nil,onReady:@escaping ()->Void) {
        guard !active,!choosing,!ready,!ScreenContext.shared.active else{onFailure?("Another capture selection is active.");return}
        choosing=true
        starting=Task {
            do {
                let filter=try await withTaskCancellationHandler {
                    try Task.checkCancellation()
                    return try await withCheckedThrowingContinuation { continuation in
                        selection=continuation
                        var settings=SCContentSharingPickerConfiguration()
                        settings.allowedPickerModes=expectedBundle==nil ? [.singleWindow,.singleApplication,.singleDisplay]:[.singleWindow]
                        settings.excludedBundleIDs=[Bundle.main.bundleIdentifier ?? "local.mewpon.desktop"]
                        settings.allowsChangingSelectedContent=false
                        let picker=SCContentSharingPicker.shared
                        picker.defaultConfiguration=settings;picker.add(self);picker.isActive=true;picker.present()
                    }
                } onCancel:{Task{@MainActor in self.finishSelection(.failure(CancellationError()))}}
                try Task.checkCancellation()
                if #available(macOS 15.2,*) {
                    let windows=filter.includedWindows
                    let apps=filter.includedApplications
                    if let expectedBundle {
                        guard filter.style == .window,!windows.isEmpty,windows.allSatisfy({$0.owningApplication?.bundleIdentifier==expectedBundle}) else{throw MewponError.invalid("The selected target does not match the requested application. Capture did not start. Choose its window in macOS.")}
                    }
                    targetDescription=filter.style == .display ? "Selected display":windows.map{($0.owningApplication?.applicationName ?? "Application")+" · "+($0.title ?? "Window")}.joined(separator:"; ")
                    if targetDescription.isEmpty{targetDescription=apps.map{$0.applicationName}.joined(separator:"; ")}
                }else if expectedBundle != nil {throw MewponError.unavailable("Application validation for picker targets requires macOS 15.2 or later.")}
                else{targetDescription="Target selected in macOS"}
                let configuration=SCStreamConfiguration()
                let rect=filter.contentRect,scale=min(Double(filter.pointPixelScale),1280/max(1,rect.width,rect.height))
                configuration.width=slides ? max(2,Int(rect.width*scale)):2
                configuration.height=slides ? max(2,Int(rect.height*scale)):2
                configuration.minimumFrameInterval=CMTime(value:1,timescale:1)
                configuration.queueDepth=3;configuration.showsCursor=false
                configuration.capturesAudio=true;configuration.sampleRate=48000;configuration.channelCount=1;configuration.excludesCurrentProcessAudio=true
                let output=MeetingCaptureSink(slides:slides,chunk:{[weak self] url in await self?.deliverChunk(url)},slide:{[weak self] data,time in await self?.deliverSlide(data,time)},failure:{[weak self] message in Task{@MainActor in self?.onFailure?(message);await self?.stop()}})
                let stream=SCStream(filter:filter,configuration:configuration,delegate:self)
                try stream.addStreamOutput(output,type:.audio,sampleHandlerQueue:output.queue)
                if slides{try stream.addStreamOutput(output,type:.screen,sampleHandlerQueue:output.queue)}
                self.sink=output;self.stream=stream
                choosing=false;ready=true;onReady()
            }catch{choosing=false;onFailure?(error is CancellationError ? "Capture selection cancelled; nothing was recorded.":error.localizedDescription);await stop()}
        }
    }
    func startPrepared() async throws {
        guard ready,let stream else{throw MewponError.invalid("Choose and review a capture target first.")}
        await sink?.resetStart()
        try await stream.startCapture();active=true;ready=false
        try Task.checkCancellation()
    }
    func stop() async {
        if let stopJob{await stopJob.value;return}
        let job=Task{await performStop()};stopJob=job
        await job.value;stopJob=nil
    }
    private func performStop() async {
        starting?.cancel();starting=nil
        let stream=self.stream,wasActive=active;self.stream=nil;active=false;choosing=false;ready=false
        if let stream,wasActive{try? await stream.stopCapture()}
        if let sink{await sink.finish()};sink=nil
        finishSelection(.failure(CancellationError()))
        SCContentSharingPicker.shared.remove(self);SCContentSharingPicker.shared.isActive=false
    }
    private func finishSelection(_ result:Result<SCContentFilter,Error>) {let pending=selection;selection=nil;pending?.resume(with:result)}
    private func deliverChunk(_ url:URL){onChunk?(url)}
    private func deliverSlide(_ data:Data,_ time:Double){onSlide?(data,time)}
    nonisolated func contentSharingPicker(_ picker:SCContentSharingPicker,didCancelFor stream:SCStream?){Task{@MainActor in self.finishSelection(.failure(CancellationError()))}}
    nonisolated func contentSharingPicker(_ picker:SCContentSharingPicker,didUpdateWith filter:SCContentFilter,for stream:SCStream?){guard stream==nil else{return};Task{@MainActor in self.finishSelection(.success(filter))}}
    nonisolated func contentSharingPickerStartDidFailWithError(_ error:Error){Task{@MainActor in self.finishSelection(.failure(error))}}
    nonisolated func stream(_ stream:SCStream,didStopWithError error:Error){Task{@MainActor in self.onFailure?(error.localizedDescription);await self.stop()}}
}

/// Serial callback queue owns PCM buffers and file writes; the UI never handles each audio sample.
final class MeetingCaptureSink:NSObject,SCStreamOutput,@unchecked Sendable {
    let queue=DispatchQueue(label:"local.mewpon.meeting-capture",qos:.userInitiated)
    private let slides:Bool
    private let chunk:@Sendable(URL) async ->Void
    private let slide:@Sendable(Data,Double) async ->Void
    private let failure:@Sendable(String)->Void
    private var file:AVAudioFile?
    private var url:URL?
    private var frames:AVAudioFramePosition=0
    private var ended=false
    private var deliveries:[Task<Void,Never>]=[]
    private var slideCount=0
    private var began=ContinuousClock.now
    private var lastSlide = -10.0
    private var fingerprint:[UInt8]?
    private let context=CIContext(options:[.cacheIntermediates:false])
    init(slides:Bool,chunk:@escaping @Sendable(URL) async ->Void,slide:@escaping @Sendable(Data,Double) async ->Void,failure:@escaping @Sendable(String)->Void){self.slides=slides;self.chunk=chunk;self.slide=slide;self.failure=failure}
    func stream(_ stream:SCStream,didOutputSampleBuffer sampleBuffer:CMSampleBuffer,of type:SCStreamOutputType) {
        consume(sampleBuffer,type:type)
    }
    /// Call only on queue; exposed internally for controlled PCM fixtures.
    func consume(_ sampleBuffer:CMSampleBuffer,type:SCStreamOutputType) {
        guard !ended,sampleBuffer.isValid else{return}
        do {
            guard elapsedMilliseconds(since:began)<7_200_000 else{throw MewponError.invalid("The two-hour session limit was reached. Start a new recording to continue.")}
            if type == .audio {
                try sampleBuffer.withAudioBufferList { list,_ in
                    guard let description=sampleBuffer.formatDescription else{throw MewponError.invalid("Captured audio has no format.")}
                    let format=AVAudioFormat(cmAudioFormatDescription:description)
                    guard let pcm=AVAudioPCMBuffer(pcmFormat:format,bufferListNoCopy:list.unsafePointer) else{throw MewponError.invalid("Unsupported captured audio format.")}
                    guard pcm.frameLength>0 else{return}
                    if file==nil {
                        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("Mewpon-system-audio")
                        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
                        let target=folder.appendingPathComponent(UUID().uuidString+".caf")
                        file=try AVAudioFile(forWriting:target,settings:format.settings);url=target;frames=0
                        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:target.path)
                    }
                    try file?.write(from:pcm);frames += AVAudioFramePosition(pcm.frameLength)
                    if Double(frames)/format.sampleRate>=30{closeChunk()}
                }
            } else if type == .screen,slides,let pixel=sampleBuffer.imageBuffer {
                guard slideCount<240,let attachments=CMSampleBufferGetSampleAttachmentsArray(sampleBuffer,createIfNecessary:false) as? [[SCStreamFrameInfo:Any]],let raw=attachments.first?[.status] as? Int,SCFrameStatus(rawValue:raw) == .complete else{return}
                let now=elapsedMilliseconds(since:began)/1000
                guard now-lastSlide>=3 else{return}
                let image=CIImage(cvPixelBuffer:pixel),size=CGSize(width:32,height:18)
                let reduced=image.transformed(by:CGAffineTransform(scaleX:size.width/image.extent.width,y:size.height/image.extent.height))
                var pixels=[UInt8](repeating:0,count:32*18*4)
                context.render(reduced,toBitmap:&pixels,rowBytes:32*4,bounds:CGRect(origin:.zero,size:size),format:.RGBA8,colorSpace:CGColorSpaceCreateDeviceRGB())
                var gray:[UInt8]=[]
                for i in stride(from:0,to:pixels.count,by:4){let sum=Int(pixels[i])+Int(pixels[i+1])+Int(pixels[i+2]);gray.append(UInt8(sum/3))}
                guard SlideChange.meaningful(previous:fingerprint,current:gray) else{return}
                guard let cg=context.createCGImage(image,from:image.extent),let data=NSBitmapImageRep(cgImage:cg).representation(using:.png,properties:[:]) else{return}
                fingerprint=gray;lastSlide=now;slideCount += 1;deliveries.append(Task{await slide(data,now)})
            }
        }catch{ended=true;closeChunk();failure(error.localizedDescription)}
    }
    private func closeChunk(){file=nil;if let url{self.url=nil;deliveries.append(Task{await chunk(url)})};frames=0}
    func resetStart() async {await withCheckedContinuation{c in queue.async{self.began = .now;c.resume()}}}
    func finish() async {
        let pending:[Task<Void,Never>]=await withCheckedContinuation{c in queue.async{self.ended=true;self.closeChunk();c.resume(returning:self.deliveries);self.deliveries=[]}}
        for task in pending{await task.value}
    }
}
