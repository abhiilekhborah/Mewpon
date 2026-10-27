import AppKit
import MewponCore

/// A late LaunchServices callback must not resume a cancelled request twice.
final class NativeOpenCompletion:@unchecked Sendable {
    private let lock=NSLock()
    private var continuation:CheckedContinuation<ToolResult,Error>?
    private var finished=false
    func install(_ value:CheckedContinuation<ToolResult,Error>)->Bool {
        lock.lock()
        if finished{lock.unlock();value.resume(throwing:CancellationError());return false}
        continuation=value;lock.unlock();return true
    }
    func complete(_ result:Result<ToolResult,Error>){
        lock.lock();guard !finished else{lock.unlock();return};finished=true
        let value=continuation;continuation=nil;lock.unlock();value?.resume(with:result)
    }
    func cancel(){complete(.failure(CancellationError()))}
}

enum NativeWorkspaceOpen {
    @MainActor static func openProject(_ url:URL,editor:URL) async throws ->ToolResult {
        try await openDocument(url, application: editor, displayName: "VS Code")
    }
    @MainActor static func openDocument(_ url: URL, application editor: URL, displayName: String) async throws -> ToolResult {
        let gate=NativeOpenCompletion()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                guard gate.install(continuation) else{return}
                NSWorkspace.shared.open([url],withApplicationAt:editor,configuration:NSWorkspace.OpenConfiguration()){_,error in
                    if let error{gate.complete(.failure(error))}
                    else{gate.complete(.success(ToolResult(true,"macOS accepted the request to open \(url.lastPathComponent) in \(displayName).")))}
                }
            }
        } onCancel:{gate.cancel()}
    }

    @MainActor static func open(_ url:URL,application:Bool) async throws ->ToolResult {
        // For folders, completion callbacks may wait for Finder's application
        // lifecycle even after the folder has opened. Report OS acceptance instead.
        if !application, (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            let request = Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                let accepted = NSWorkspace.shared.open(url)
                return ToolResult(accepted, accepted ? "macOS accepted the request to open " + url.lastPathComponent + " in Finder." : "macOS could not accept the folder-open request.")
            }
            return try await withTaskCancellationHandler { try await request.value } onCancel: { request.cancel() }
        }
        let gate=NativeOpenCompletion()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                guard gate.install(continuation) else{return}
                let configuration=NSWorkspace.OpenConfiguration();configuration.activates=true
                let completion:@Sendable(NSRunningApplication?,Error?)->Void = {_,error in
                    if let error{gate.complete(.failure(error))}
                    else{let name=application ? url.deletingPathExtension().lastPathComponent:url.lastPathComponent;gate.complete(.success(ToolResult(true,"Opened "+name+".")))}
                }
                if application{NSWorkspace.shared.openApplication(at:url,configuration:configuration,completionHandler:completion)}
                else{NSWorkspace.shared.open(url,configuration:configuration,completionHandler:completion)}
            }
        } onCancel:{gate.cancel()}
    }
}
