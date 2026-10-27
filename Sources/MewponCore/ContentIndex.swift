import Foundation
import CSQLite
import Darwin

public enum LocalPath {
    /// Resolve the deepest existing ancestor before appending a new destination.
    public static func canonicalDestination(_ path: String) -> String {
        var ancestor = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        var suffix: [String] = []
        while !FileManager.default.fileExists(atPath: ancestor.path), ancestor.path != "/" {
            suffix.insert(ancestor.lastPathComponent, at: 0); ancestor.deleteLastPathComponent()
        }
        var resolved = canonical(ancestor.path)
        for component in suffix { resolved = (resolved as NSString).appendingPathComponent(component) }
        return resolved
    }
    public static func canonical(_ path:String)->String {
        guard let resolved=realpath(path,nil) else{return URL(fileURLWithPath:path).standardizedFileURL.path}
        defer{free(resolved)};return String(cString:resolved)
    }
}

public struct IndexedFile: Sendable, Equatable {
    public var path:String;public var modified:Date;public var size:Int;public var text:String
    public init(path:String,modified:Date,size:Int,text:String){self.path=path;self.modified=modified;self.size=size;self.text=text}
}
/// Serialized SQLite access. No disk traversal or document decoding on the UI thread.
public actor ContentIndex {
    private var db:OpaquePointer?
    private let transient=unsafeBitCast(-1,to:sqlite3_destructor_type.self)
    public init(url:URL) throws {
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        guard sqlite3_open(url.path,&db)==SQLITE_OK else{throw MewponError.unavailable("Cannot open the local search index.")}
        guard sqlite3_exec(db,"PRAGMA journal_mode=WAL; CREATE VIRTUAL TABLE IF NOT EXISTS documents USING fts5(path UNINDEXED, root UNINDEXED, modified UNINDEXED, size UNINDEXED, name, content, aliases, tokenize='unicode61 remove_diacritics 2');",nil,nil,nil)==SQLITE_OK else{sqlite3_close(db);db=nil;throw MewponError.unavailable("SQLite FTS5 is unavailable.")}
        try? FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
    }
    deinit{sqlite3_close(db)}
    private func statement(_ sql:String,_ values:[String]) throws ->OpaquePointer {
        var stmt:OpaquePointer?
        guard sqlite3_prepare_v2(db,sql,-1,&stmt,nil)==SQLITE_OK,let stmt else{throw MewponError.unavailable("Local index query failed.")}
        for (i,value) in values.enumerated(){sqlite3_bind_text(stmt,Int32(i+1),value,-1,transient)}
        return stmt
    }
    private func column(_ stmt:OpaquePointer,_ n:Int32)->String {sqlite3_column_text(stmt,n).map{String(cString:$0)} ?? ""}
    public func metadata(root:String) throws ->[String:String] {
        let stmt=try statement("SELECT path,modified,size FROM documents WHERE root=?",[root]);defer{sqlite3_finalize(stmt)}
        var result:[String:String]=[:]
        while sqlite3_step(stmt)==SQLITE_ROW{result[column(stmt,0)]=column(stmt,1)+":"+column(stmt,2)}
        return result
    }
    public func upsert(_ file:IndexedFile,root:String) throws {
        let prior=try statement("SELECT aliases FROM documents WHERE path=? LIMIT 1",[file.path]);let alias=sqlite3_step(prior)==SQLITE_ROW ? column(prior,0):"";sqlite3_finalize(prior)
        try remove(path:file.path)
        let stmt=try statement("INSERT INTO documents(path,root,modified,size,name,content,aliases) VALUES(?,?,?,?,?,?,?)",[file.path,root,String(file.modified.timeIntervalSince1970),String(file.size),URL(fileURLWithPath:file.path).lastPathComponent,file.text,alias]);defer{sqlite3_finalize(stmt)}
        guard sqlite3_step(stmt)==SQLITE_DONE else{throw MewponError.unavailable("Local index update failed.")}
    }
    public func remove(path:String) throws {let stmt=try statement("DELETE FROM documents WHERE path=?",[path]);defer{sqlite3_finalize(stmt)};sqlite3_step(stmt)}
    public func removeRoot(_ root:String) throws {let stmt=try statement("DELETE FROM documents WHERE root=?",[root]);defer{sqlite3_finalize(stmt)};sqlite3_step(stmt)}
    public func remember(path:String,alias:String) throws {
        let safe=CommandVocabulary.searchTokens(alias).prefix(12).joined(separator:" ")
        let stmt=try statement("UPDATE documents SET aliases=? WHERE path=?",[safe,path]);defer{sqlite3_finalize(stmt)}
        guard sqlite3_step(stmt)==SQLITE_DONE,sqlite3_changes(db)>0 else{throw MewponError.invalid("This file is not indexed. Refresh its authorized folder first.")}
    }
    public func search(_ query:FileSearchQuery,authorizedRoots:Set<String>) throws ->[ResultItem] {
        let terms=Array(CommandVocabulary.searchTokens(query.name).prefix(12))
        let match=terms.flatMap { term -> [String] in
            let safe=term.replacingOccurrences(of:"\"",with:"")
            return ["\""+safe+"\"*"] + (safe.count>=5 ? ["\""+String(safe.prefix(4))+"\"*"]:[])
        }.joined(separator:" OR ")
        let sql=match.isEmpty ? "SELECT path,root,modified,size FROM documents LIMIT 256":"SELECT path,root,modified,size FROM documents WHERE documents MATCH ? ORDER BY bm25(documents,0,0,0,0,6,1,12) LIMIT 256"
        let stmt=try statement(sql,match.isEmpty ? []:[match]);defer{sqlite3_finalize(stmt)}
        var ranked:[(ResultItem,Double)]=[]
        while sqlite3_step(stmt)==SQLITE_ROW {
            let path=column(stmt,0),root=column(stmt,1),url=URL(fileURLWithPath:path)
            guard authorizedRoots.contains(root),LocalPath.canonical(path).hasPrefix(root+"/"),FileManager.default.isReadableFile(atPath:path),let values=try? url.resourceValues(forKeys:[.contentModificationDateKey,.fileSizeKey]),let date=values.contentModificationDate,abs(date.timeIntervalSince1970-(Double(column(stmt,2)) ?? 0))<0.01,values.fileSize==Int(column(stmt,3)) else{continue}
            guard query.extensions.isEmpty || query.extensions.contains(url.pathExtension.lowercased()) else{continue}
            if let interval=query.modifiedInterval(),!interval.contains(date){continue}
            var item=ResultItem(name:url.lastPathComponent,path:path,kind:url.pathExtension);item.modifiedAt=date
            let names=CommandVocabulary.searchTokens(url.deletingPathExtension().lastPathComponent)
            let similarity=terms.reduce(0.0){score,term in score+(names.contains(term) ? 3:names.contains(where:{CommandVocabulary.distance(term,$0)<=1}) ? 1:0)}
            ranked.append((item,similarity))
        }
        // Preserve FTS relevance ties; filename evidence can promote an exact match.
        return ranked.enumerated().sorted{a,b in a.element.1==b.element.1 ? a.offset<b.offset:a.element.1>b.element.1}.prefix(20).map{$0.element.0}
    }
}
