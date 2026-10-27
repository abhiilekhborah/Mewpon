import AppKit
import Foundation
import IOKit.ps
import MewponCore
import UniformTypeIdentifiers

struct OpenApplicationTool: AssistantTool {
    let spec = ToolSpec("open_application", "Open an installed application by exact name, bundle identifier, or an installed application path returned by a previous result. Ambiguous matches return choices.", fields: ["application": "Application name, bundle identifier, or selected installed .app path"], capability: .launchApplication, timeout: 15)
    private static var applicationRoots: [String] { ["/Applications", "/System/Applications", "/System/Library/CoreServices", "/System/Cryptexes/App/System/Applications", NSHomeDirectory() + "/Applications"] }
    static func bundleIdentifier(for name: String) -> String {
        let aliases = ["safari": "com.apple.Safari", "finder": "com.apple.finder", "terminal": "com.apple.Terminal", "vs code": "com.microsoft.VSCode", "vscode": "com.microsoft.VSCode", "visual studio code": "com.microsoft.VSCode"]
        return aliases[name.lowercased()] ?? name
    }
    static func resolve(_ name:String) async throws ->[ResultItem] {
        try await ApplicationRegistry.shared.resolve(name)
    }
    func execute(arguments: [String: JSONValue]) async throws -> ToolResult {
        let name = arguments["application"]!.string!
        let candidates = try await Self.resolve(name)
        guard !candidates.isEmpty else { return ToolResult(false, "Application ‘\(name)’ was not found.") }
        guard candidates.count == 1 else { return ToolResult(false, "More than one application matches. Choose an exact application name or bundle identifier.", items: candidates) }
        try Task.checkCancellation()
        let url = URL(fileURLWithPath: candidates[0].path)
        return try await NativeWorkspaceOpen.open(url,application:true)
    }

}

struct FileSearchTool: AssistantTool {
    let onProgress:@Sendable(ToolResult) async ->Void
    init(onProgress:@escaping @Sendable(ToolResult) async ->Void = {_ in}){self.onProgress=onProgress}
    let spec = ToolSpec("search_files", "Search Spotlight metadata plus the local content index for explicitly authorized folders. Supports purpose, filename, file type, and dates. Bounded results may be incomplete.", fields: ["query": "Filename or supported type and modification-date filter"], capability: .searchFiles, timeout: 8)
    func execute(arguments:[String:JSONValue]) async throws ->ToolResult {
        let parsed=FileSearchQuery.parse(arguments["query"]!.string!)
        let indexed=(try? await AuthorizedSearch.shared.search(parsed)) ?? []
        if !indexed.isEmpty {var initial=ToolResult(true,"Initial matches from authorized content index.",items:indexed);initial.partial=true;await onProgress(initial)}
        Task(priority:.utility){await AuthorizedSearch.shared.refresh()}
        let spotlight=try await SpotlightSearch().search(parsed,onProgress:{result in
            var merged=result
            merged.items=Array((indexed+result.items).reduce(into:[ResultItem]()){items,item in if !items.contains(where:{$0.path==item.path}){items.append(item)}}.prefix(20))
            await onProgress(merged)
        })
        let local=(try? await AuthorizedSearch.shared.search(parsed)) ?? indexed
        var merged=spotlight
        merged.items=Array((local+spotlight.items).reduce(into:[ResultItem]()){items,item in if !items.contains(where:{$0.path==item.path}){items.append(item)}}.prefix(20))
        merged.summary=merged.items.isEmpty ? "No indexed match. Content search covers only folders you add in Settings → Privacy.":"Found \(merged.items.count) matching files. Content search covers authorized folders; choose the intended result."
        // Hybrid retrieval is bounded: a sole result does not prove a unique file on disk.
        if !local.isEmpty{merged.partial=true;merged.summary+=" Results may be incomplete."}
        return merged
    }
}

@MainActor final class SpotlightSearch {
    private let scopes:[String]
    init(scopes:[String]=[NSHomeDirectory()]){self.scopes=scopes}
    private var query:NSMetadataQuery?
    private var observers:[NSObjectProtocol]=[]
    private var continuation:CheckedContinuation<ToolResult,Error>?
    private var deadline:Task<Void,Never>?
    private var processing=false
    private var parsed=FileSearchQuery.parse("")
    private var pendingFinish=false
    private var pendingPartial=false
    private var lastProgress=ContinuousClock.now
    private var onProgress:@Sendable(ToolResult) async ->Void = {_ in}
    func search(_ term:String) async throws ->ToolResult {try await search(FileSearchQuery.parse(term))}
    func search(_ term:FileSearchQuery,onProgress:@escaping @Sendable(ToolResult) async ->Void = {_ in}) async throws ->ToolResult {
        return try await withTaskCancellationHandler {
            try Task.checkCancellation();self.parsed=term;self.onProgress=onProgress
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation=continuation
                let query=NSMetadataQuery();self.query=query;query.searchScopes=scopes;query.notificationBatchingInterval=0.1
                if term.largest { query.sortDescriptors = [NSSortDescriptor(key: "kMDItemFSSize", ascending: false)] }
                var predicates:[NSPredicate]=[]
                if term.extensions == ["png"], term.screenshots { predicates.append(NSPredicate(format: "%K == 1", "kMDItemIsScreenCapture")) }
                if !term.name.isEmpty {
                    let tokens=CommandVocabulary.searchTokens(term.name).prefix(8)
                    var names:[NSPredicate]=[NSPredicate(format:"%K CONTAINS[cd] %@",NSMetadataItemFSNameKey,term.name)]
                    for token in tokens {
                        names.append(NSPredicate(format:"%K CONTAINS[cd] %@",NSMetadataItemFSNameKey,token))
                        if token=="resume"{names.append(NSPredicate(format:"%K CONTAINS[cd] %@",NSMetadataItemFSNameKey,"cv"))}
                        if token.count>=5{names.append(NSPredicate(format:"%K CONTAINS[cd] %@",NSMetadataItemFSNameKey,String(token.prefix(4))))}
                    }
                    predicates.append(names.count==1 ? names[0]:NSCompoundPredicate(orPredicateWithSubpredicates:names))
                }
                if !term.extensions.isEmpty {
                    let types=term.extensions.map{NSPredicate(format:"%K ENDSWITH[cd] %@",NSMetadataItemFSNameKey,"."+$0)}
                    // NSMetadataQuery rejects AND/OR nodes with just one child.
                    predicates.append(types.count==1 ? types[0]:NSCompoundPredicate(orPredicateWithSubpredicates:types))
                }
                if let interval=term.modifiedInterval(){predicates.append(NSPredicate(format:"%K >= %@ AND %K < %@",NSMetadataItemFSContentChangeDateKey,interval.start as NSDate,NSMetadataItemFSContentChangeDateKey,interval.end as NSDate))}
                guard !predicates.isEmpty else{complete(.success(ToolResult(false,"Please specify a filename or file type.")));return}
                query.predicate=predicates.count==1 ? predicates[0]:NSCompoundPredicate(andPredicateWithSubpredicates:predicates)
                // Rank bounded results after gathering rather than using Spotlight sort descriptors.
                for name in [Notification.Name.NSMetadataQueryGatheringProgress,.NSMetadataQueryDidUpdate,.NSMetadataQueryDidFinishGathering]{
                    observers.append(NotificationCenter.default.addObserver(forName:name,object:query,queue:.main){[weak self] note in
                        let finished=note.name == .NSMetadataQueryDidFinishGathering
                        Task{@MainActor in self?.gather(finished:finished)}
                    })
                }
                deadline=Task{[weak self] in do{try await Task.sleep(for:.seconds(5));self?.gather(finished:true,partial:true)}catch{}}
                if !query.start(){complete(.failure(MewponError.unavailable("Spotlight could not start. Check file access and indexing.")))}
            }
        } onCancel:{Task{@MainActor in self.complete(.failure(CancellationError()))}}
    }
    private func gather(finished:Bool,partial:Bool=false){
        guard let query else{return}
        if processing{pendingFinish = pendingFinish || finished;pendingPartial = pendingPartial || partial;return}
        guard finished || query.resultCount>0 && lastProgress.duration(to:.now) > .milliseconds(80) else{return}
        lastProgress = .now;query.disableUpdates()
        var paths:[String]=[],dates:[String:Date]=[:]
        for i in 0..<min(query.resultCount,256){
            if let item=query.result(at:i) as? NSMetadataItem,let path=item.value(forAttribute:NSMetadataItemPathKey) as? String{
                paths.append(path);dates[path]=item.value(forAttribute:NSMetadataItemFSContentChangeDateKey) as? Date
            }
        }
        query.enableUpdates()
        let bounded=query.resultCount>=256,shouldFinish=finished || paths.count>=20 && !parsed.largest
        if shouldFinish{query.stop();deadline?.cancel();deadline=nil}
        let name=parsed.name,home=NSHomeDirectory(),callback=onProgress,largest=parsed.largest
        processing=true
        let snapshotPaths=paths,snapshotDates=dates
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            let safe=Set(snapshotPaths.map{URL(fileURLWithPath:$0).resolvingSymlinksInPath().path}).filter{$0.hasPrefix(home+"/") && FileManager.default.fileExists(atPath:$0)}
            let rankOrder = Dictionary(snapshotPaths.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: min)
            let ranked=safe.sorted{a,b in
                if largest { return (rankOrder[a] ?? Int.max) < (rankOrder[b] ?? Int.max) }
                let an=URL(fileURLWithPath:a).deletingPathExtension().lastPathComponent.lowercased(),bn=URL(fileURLWithPath:b).deletingPathExtension().lastPathComponent.lowercased()
                let tokens=CommandVocabulary.searchTokens(name)
                func score(_ n:String)->Int {tokens.reduce(0){ score,token in score+(n.contains(token) ? 3:CommandVocabulary.searchTokens(n).contains(where:{CommandVocabulary.distance(token,$0)<=1}) ? 1:0)}}
                let ar=an==name ? -100:-score(an),br=bn==name ? -100:-score(bn)
                if ar != br{return ar<br}
                let ad=snapshotDates[a] ?? .distantPast,bd=snapshotDates[b] ?? .distantPast
                return ad==bd ? a<b:ad>bd
            }
            let items=ranked.prefix(20).map { path in
                var item = ResultItem(name:URL(fileURLWithPath:path).lastPathComponent,path:path,kind:URL(fileURLWithPath:path).pathExtension)
                item.modifiedAt = snapshotDates[path]
                return item
            }
            var result=ToolResult(true,items.isEmpty ? "No indexed matching files found. Indexing or macOS access may limit results. Use Choose file if needed.":"Found \(items.count) matching files. Choose the intended path if several match.",items:Array(items))
            result.partial=partial || bounded || !finished
            if result.partial==true{result.summary+=" Results may be incomplete."}
            let completed=result
            Task{@MainActor [weak self] in
                guard let self,self.continuation != nil else{return}
                self.processing=false
                if shouldFinish{self.complete(.success(completed))}else{
                    await callback(completed)
                    if self.pendingFinish{let partial=self.pendingPartial;self.pendingFinish=false;self.pendingPartial=false;self.gather(finished:true,partial:partial)}
                }
            }
        }
    }

    private func complete(_ result:Result<ToolResult,Error>){
        guard let continuation else{return};self.continuation=nil
        deadline?.cancel();deadline=nil;processing=false;query?.stop();query=nil
        observers.forEach(NotificationCenter.default.removeObserver);observers=[]
        continuation.resume(with:result)
    }
}

struct OpenFileTool: AssistantTool {
    private static let folders=["downloads":NSHomeDirectory()+"/Downloads","documents":NSHomeDirectory()+"/Documents","desktop":NSHomeDirectory()+"/Desktop","home":NSHomeDirectory()]
    let spec = ToolSpec("open_path", "Open an actual document or folder. Supply an absolute path, ~/ path, or known folder alias Downloads, Documents, Desktop, Home. Executable content is not allowed.", fields: ["path": "Existing document/folder path or known folder alias"], capability: .openPath)
    func execute(arguments: [String: JSONValue]) async throws -> ToolResult {
        let input = arguments["path"]!.string!
        let path = Self.folders[input.lowercased()] ?? (input as NSString).expandingTildeInPath
        guard path.hasPrefix("/") else { return ToolResult(false, "An absolute existing path is required. Search for the file first.") }
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) else { return ToolResult(false, "The path does not exist or macOS has denied access.") }
        let forbidden = ["app", "command", "sh", "bash", "zsh", "py", "rb", "pl", "js", "scpt", "applescript", "workflow", "shortcut", "pkg", "dmg", "webloc", "url", "html", "htm"]
        guard !forbidden.contains(url.pathExtension.lowercased()) else { return ToolResult(false, "Opening executable content, scripts, packages, and web links is outside MVP scope.") }
        let values = try url.resourceValues(forKeys: [.isExecutableKey, .isPackageKey])
        guard values.isPackage != true,
              directory.boolValue || values.isExecutable != true else { return ToolResult(false, "Opening executable content, scripts, packages, and web links is outside MVP scope.") }
        if !directory.boolValue {
            guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .text) || type.conforms(to: .image) || type.conforms(to: .pdf) || type.conforms(to: .audio) || type.conforms(to: .movie) || ["docx", "xlsx", "pptx", "pages", "numbers", "key"].contains(url.pathExtension.lowercased()) else {
                return ToolResult(false, "This file type is not an approved document type in MVP v1.")
            }
            guard FileManager.default.isReadableFile(atPath: url.path) else { return ToolResult(false, "File access denied by macOS. Use Choose file to grant access.") }
        }
        try Task.checkCancellation()
        return try await NativeWorkspaceOpen.open(url,application:false)
    }
}

struct SystemInfoTool: AssistantTool {
    private static let deviceDetails:[String] = {
        var lines=["macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)"]
        var size=0;sysctlbyname("hw.model",nil,&size,nil,0)
        var model=[CChar](repeating:0,count:max(1,size))
        if sysctlbyname("hw.model",&model,&size,nil,0)==0{lines.append("Device model: \(String(cString:model))")}
        lines.append(String(format:"Physical memory: %.1f GiB",Double(ProcessInfo.processInfo.physicalMemory)/1_073_741_824))
        return lines
    }()
    let spec = ToolSpec("system_info", "Read actual battery, charging, storage, memory, macOS version, and hardware model from native APIs.")
    func execute(arguments: [String: JSONValue]) async throws -> ToolResult {
        try await Task.detached(priority: .userInitiated) {
            var lines = Self.deviceDetails
            let gib = 1_073_741_824.0
            var stats = vm_statistics64()
            var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
            let status = withUnsafeMutablePointer(to: &stats) { ptr in
                ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
            }
            if status == KERN_SUCCESS {
                lines.append(String(format: "Free + inactive memory: %.2f GiB (not an application memory budget)", Double(UInt64(stats.free_count) + UInt64(stats.inactive_count)) * Double(vm_kernel_page_size) / gib))
            } else { lines.append("Memory statistics unavailable.") }
            let storage = try URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
            if let available = storage.volumeAvailableCapacityForImportantUsage { lines.append(String(format: "Storage available for use: %.1f GiB", Double(available) / gib)) }
            if let total = storage.volumeTotalCapacity { lines.append(String(format: "Storage total: %.1f GiB", Double(total) / gib)) }
            if let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(), let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef], !sources.isEmpty {
                for source in sources {
                    if let info = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                       let current = info[kIOPSCurrentCapacityKey] as? Int, let max = info[kIOPSMaxCapacityKey] as? Int, max > 0 {
                        let charging = info[kIOPSIsChargingKey] as? Bool ?? false
                        let power = info[kIOPSPowerSourceStateKey] as? String ?? "unknown"
                        lines.append("Battery: \(Int(Double(current) / Double(max) * 100))%; charging: \(charging ? "yes" : "no"); power: \(power)")
                    }
                }
            } else { lines.append("Battery information unavailable (no battery source reported).") }
            return ToolResult(true, lines.joined(separator: "\n"))
        }.value
    }
}
