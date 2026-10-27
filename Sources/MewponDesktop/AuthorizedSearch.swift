import AppKit
import MewponCore

/// Folder selection is the authorization boundary for persistent content extraction.
actor AuthorizedSearch {
    static let shared=AuthorizedSearch()
    private var index:ContentIndex?
    private var refreshing=false
    private(set) var complete=false
    private var lastRefresh=Date.distantPast
    private let defaults:UserDefaults
    init(defaults:UserDefaults = .standard){self.defaults=defaults}
    private func database() throws ->ContentIndex {
        if let index{return index}
        let base=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent(Bundle.main.bundleIdentifier ?? "local.mewpon.desktop")
        let value=try ContentIndex(url:base.appendingPathComponent("Search/content.sqlite"));index=value;return value
    }
    func roots()->[URL] {
        (defaults.array(forKey:"searchFolderBookmarks") as? [Data] ?? []).compactMap { data in
            var stale=false
            guard let url=try? URL(resolvingBookmarkData:data,options:.withoutUI,bookmarkDataIsStale:&stale) else{return nil}
            return URL(fileURLWithPath:LocalPath.canonical(url.path))
        }
    }
    func authorize(_ url:URL) async throws {
        let canonical=URL(fileURLWithPath:LocalPath.canonical(url.path))
        guard canonical.path != "/",canonical.path != NSHomeDirectory(),canonical.pathComponents.count>2 else{throw MewponError.invalid("Choose a specific documents or project folder, rather than the whole home folder or disk.")}
        var bookmarks=defaults.array(forKey:"searchFolderBookmarks") as? [Data] ?? []
        if !roots().contains(canonical){bookmarks.append(try canonical.bookmarkData(options:[],includingResourceValuesForKeys:nil,relativeTo:nil));defaults.set(bookmarks,forKey:"searchFolderBookmarks")}
        await refresh(force:true)
    }
    func clear() async throws {
        let prior=roots();defaults.removeObject(forKey:"searchFolderBookmarks")
        let db=try database()
        for root in prior{try await db.removeRoot(root.path)}
        lastRefresh = .distantPast
    }
    func refresh(force:Bool=false) async {
        guard !refreshing,force || Date().timeIntervalSince(lastRefresh)>30 else{return}
        refreshing=true;complete=false;var allComplete = !roots().isEmpty
        defer{refreshing=false;complete=allComplete;lastRefresh=Date()}
        guard let db=try? database() else{return}
        for root in roots() {
            let access=root.startAccessingSecurityScopedResource();defer{if access{root.stopAccessingSecurityScopedResource()}}
            var traversalFailed=false
            guard let old=try? await db.metadata(root:root.path),let iterator=FileManager.default.enumerator(at:root,includingPropertiesForKeys:[.isDirectoryKey,.isSymbolicLinkKey,.isRegularFileKey,.contentModificationDateKey,.fileSizeKey],options:[.skipsHiddenFiles,.skipsPackageDescendants],errorHandler:{_,_ in traversalFailed=true;return false}) else{allComplete=false;continue}
            var seen=Set<String>(),nodes=0,files=0,complete=true
            while let url=iterator.nextObject() as? URL {
                if Task.isCancelled || !roots().contains(root){complete=false;break}
                nodes+=1;if nodes>20_000 || files>=5_000{complete=false;break}
                guard let values=try? url.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey,.isRegularFileKey,.contentModificationDateKey,.fileSizeKey]) else{complete=false;continue}
                if values.isSymbolicLink==true{iterator.skipDescendants();continue}
                if values.isDirectory==true {
                    if ["node_modules","build","dist","vendor","Pods"].contains(url.lastPathComponent){iterator.skipDescendants()}
                    continue
                }
                guard values.isRegularFile==true,["pdf","txt","md","csv","swift","py","json","yaml","yml"].contains(url.pathExtension.lowercased()),(values.fileSize ?? Int.max)<=20_000_000,let modified=values.contentModificationDate else{continue}
                files+=1;seen.insert(url.path)
                let stamp=String(modified.timeIntervalSince1970)+":"+String(values.fileSize ?? 0)
                if old[url.path]==stamp{continue}
                guard let text=try? LocalContent.read(url) else{complete=false;try? await db.remove(path:url.path);continue}
                // A transparent rule-based purpose tag, not an embedding or LLM inference.
                let lower=text.lowercased()
                let resumeEvidence=["education","experience","skills","projects"].filter{lower.contains($0)}.count
                let tagged=text+(resumeEvidence>=3 ? "\nresume curriculum vitae":"")
                do {try await db.upsert(.init(path:url.path,modified:modified,size:values.fileSize ?? 0,text:tagged),root:root.path)} catch {complete=false}
                await Task.yield()
            }
            if traversalFailed{complete=false}
            if !complete{allComplete=false}
            if complete {for path in old.keys where !seen.contains(path){try? await db.remove(path:path)}}
        }
    }
    func search(_ query:FileSearchQuery) async throws ->[ResultItem] {
        let db=try database();return try await db.search(query,authorizedRoots:Set(roots().map(\.path)))
    }
    func remember(_ item:ResultItem,alias:String) async throws {
        let path=LocalPath.canonical(item.path)
        guard roots().contains(where:{path.hasPrefix($0.path+"/")}) else{throw MewponError.invalid("Authorize this file's folder in Settings → Privacy first.")}
        try Task.checkCancellation()
        try await database().remember(path:path,alias:alias)
    }
    func projects() async ->[ResultItem] {
        guard let db=try? database() else{return []}
        var dates:[String:Date]=[:]
        for root in roots() {
            guard let metadata=try? await db.metadata(root:root.path) else{continue}
            for path in metadata.keys where path.hasSuffix(".py") && LocalPath.canonical(path).hasPrefix(root.path+"/") && FileManager.default.fileExists(atPath:path) {
                var folder=URL(fileURLWithPath:path).deletingLastPathComponent()
                // Prefer an enclosing project marker, bounded to the authorized root.
                var parent=folder
                while parent.path.hasPrefix(root.path),parent.path != root.deletingLastPathComponent().path {
                    if ["pyproject.toml","requirements.txt","setup.py",".git"].contains(where:{FileManager.default.fileExists(atPath:parent.appendingPathComponent($0).path)}){folder=parent;break}
                    if parent==root{break};parent.deleteLastPathComponent()
                }
                let date=(try? URL(fileURLWithPath:path).resourceValues(forKeys:[.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                dates[folder.path]=max(dates[folder.path] ?? .distantPast,date)
            }
        }
        return dates.sorted{$0.value>$1.value}.prefix(20).map{var item=ResultItem(name:URL(fileURLWithPath:$0.key).lastPathComponent,path:$0.key,kind:"folder");item.modifiedAt=$0.value;return item}
    }
}

struct PythonProjectTool:AssistantTool {
    let spec=ToolSpec("python_project","Find Python projects in explicitly indexed folders. Only a sole candidate is opened; otherwise present choices. Never execute project code.",fields:["editor":"search, default, or vscode"],capability:.openPath,timeout:15)
    func execute(arguments:[String:JSONValue]) async throws ->ToolResult {
        let editor=arguments["editor"]?.string ?? "search"
        guard ["search","default","vscode"].contains(editor) else{return .init(false,"Unsupported project editor.")}
        await AuthorizedSearch.shared.refresh()
        let items=await AuthorizedSearch.shared.projects()
        let complete=await AuthorizedSearch.shared.complete
        guard !items.isEmpty else{return .init(false,"No indexed Python project was found. Add a project folder in Settings → Privacy, then refresh the index.")}
        if editor=="vscode" {return try await resolveOrOpen(items,complete:complete)}
        if editor=="search" || items.count != 1 || !complete {return .init(true,"Found \(items.count) project folders, newest first. Choose the intended folder; recency or an incomplete index does not prove intent.",items:items)}
        try Task.checkCancellation()
        let url=URL(fileURLWithPath:items[0].path)
        if editor=="default"{return try await NativeWorkspaceOpen.open(url,application:false)}
        return .init(false,"Unsupported project editor.")
    }
    private func resolveOrOpen(_ items:[ResultItem],complete:Bool) async throws ->ToolResult {
        guard items.count==1,complete else {
            let choices=items.map {item in var copy=ResultItem(name:item.name,path:item.path,kind:"python-project-vscode");copy.modifiedAt=item.modifiedAt;return copy}
            return .init(true,"Choose a Python project to open in VS Code. No project was opened automatically.",items:choices)
        }
        return try await OpenProjectTool().execute(arguments:["path":.string(items[0].path)])
    }
}

struct OpenProjectTool:AssistantTool {
    let spec=ToolSpec("open_python_project","Open an explicitly selected indexed Python project in VS Code without executing code.",fields:["path":"Absolute indexed project folder path"],capability:.openPath,timeout:15)
    func execute(arguments:[String:JSONValue]) async throws ->ToolResult {
        guard let path=arguments["path"]?.string else{return .init(false,"Select a project folder.")}
        let canonical=LocalPath.canonical(path)
        let candidates=await AuthorizedSearch.shared.projects()
        guard candidates.contains(where:{$0.path==canonical}) else{return .init(false,"This folder is no longer an authorized indexed Python project. Refresh the index and choose again.")}
        let apps=try await OpenApplicationTool.resolve("vscode")
        guard apps.count==1 else{return .init(false,"VS Code could not be uniquely resolved.",items:apps)}
        try Task.checkCancellation()
        return try await NativeWorkspaceOpen.openProject(URL(fileURLWithPath:canonical),editor:URL(fileURLWithPath:apps[0].path))
    }
}

struct RememberFileAliasTool:AssistantTool {
    let spec=ToolSpec("remember_file_alias","Store a user-confirmed alias for a file already in an authorized local content index.",fields:["path":"Actual indexed file path","alias":"User-confirmed association"],capability:.searchFiles)
    func execute(arguments:[String:JSONValue]) async throws ->ToolResult {
        guard let path=arguments["path"]?.string,let alias=arguments["alias"]?.string else{return .init(false,"Choose an indexed file and its alias.")}
        let url=URL(fileURLWithPath:path)
        try await AuthorizedSearch.shared.remember(.init(name:url.lastPathComponent,path:path,kind:url.pathExtension),alias:alias)
        return .init(true,"Remembered this file as your CV on this Mac.")
    }
}
