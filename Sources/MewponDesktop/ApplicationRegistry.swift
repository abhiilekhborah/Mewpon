import AppKit
import MewponCore

actor ApplicationRegistry {
    static let shared=ApplicationRegistry()
    static let roots=["/Applications","/System/Applications","/System/Library/CoreServices","/System/Cryptexes/App/System/Applications",NSHomeDirectory()+"/Applications"]
    private var entries:[ResultItem]=[]
    private var updated=ContinuousClock.now.advanced(by:.seconds(-121))
    private var refresh:Task<[ResultItem],Error>?
    private let lookups=BoundedCache<String,[ResultItem]>(capacity:128,ttl:.seconds(120))
    private var invalidation:UUID=UUID()
    func invalidate() async {invalidation=UUID();updated = .now.advanced(by:.seconds(-121));await lookups.removeAll()}
    func resolve(_ name:String) async throws ->[ResultItem] {
        try Task.checkCancellation()
        if name.hasPrefix("/"){return Self.validatedPath(name).map{[$0]} ?? []}
        let key=name.lowercased()
        if let found=await lookups.value(for:key),found.allSatisfy({FileManager.default.fileExists(atPath:$0.path)}){return found}
        let identifier=OpenApplicationTool.bundleIdentifier(for:name)
        let registered:[URL]=await MainActor.run {
            var urls:[URL]=[]
            if let url=NSWorkspace.shared.urlForApplication(withBundleIdentifier:identifier){urls.append(url)}
            urls.append(contentsOf:NSRunningApplication.runningApplications(withBundleIdentifier:identifier).compactMap(\.bundleURL))
            return urls
        }
        if let valid=registered.compactMap({Self.validatedPath($0.path,registeredIdentifier:identifier)}).first {
            await lookups.insert([valid],for:key);return [valid]
        }
        if updated.duration(to:.now) > .seconds(120){try await rebuild()}
        let found=ApplicationLookup.matches(query:name,candidates:entries).filter{FileManager.default.fileExists(atPath:$0.path)}.sorted{$0.path<$1.path}
        // Empty matches use the registry's two-minute expiry, not a second cache.
        if !found.isEmpty{await lookups.insert(found,for:key)}
        return found
    }
    private func rebuild() async throws {
        let version=invalidation
        if refresh==nil {
            refresh=Task.detached(priority:.utility){
                var found:[String:ResultItem]=[:]
                for root in Self.roots {
                    guard let iterator=FileManager.default.enumerator(at:URL(fileURLWithPath:root),includingPropertiesForKeys:nil,options:[.skipsHiddenFiles,.skipsPackageDescendants]) else{continue}
                    var visited=0
                    while let url=iterator.nextObject() as? URL {
                        try Task.checkCancellation();visited+=1;if visited>20_000{break}
                        if url.pathExtension=="app",let item=Self.validatedPath(url.path){found[item.path]=item;if found.count>=2048{break}}
                    }
                }
                return Array(found.values)
            }
        }
        do {
            let result=try await refresh!.value
            if version==invalidation{entries=result;updated = .now}
            refresh=nil
        } catch {refresh=nil;throw error}
    }
    nonisolated static func validatedPath(_ name:String,registeredIdentifier:String?=nil)->ResultItem? {
        let url=URL(fileURLWithPath:name).standardizedFileURL.resolvingSymlinksInPath()
        guard url.pathExtension=="app",FileManager.default.fileExists(atPath:url.path),let identifier=Bundle(url:url)?.bundleIdentifier else{return nil}
        let standardRoot=roots.contains{url.path.hasPrefix(URL(fileURLWithPath:$0).resolvingSymlinksInPath().path+"/")}
        // LaunchServices can legitimately register an app in Downloads, an
        // external volume, or App Translocation. Trust that exact OS identity,
        // never an arbitrary supplied path or an inferred replacement filename.
        guard standardRoot || registeredIdentifier==identifier else{return nil}
        return ResultItem(name:url.deletingPathExtension().lastPathComponent,path:url.path,kind:"application")
    }
}
