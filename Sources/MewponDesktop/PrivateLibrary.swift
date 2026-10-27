import Foundation
import CryptoKit
import Security
import MewponCore

/// Encrypted at rest; the key never enters preferences, the model, or logs.
struct PrivateLibrary {
    let root:URL
    private let fixtureKey:SymmetricKey?
    init(root:URL?=nil,key:SymmetricKey?=nil) {
        self.root=root ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Mewpon/PrivateLibrary")
        fixtureKey=key
    }
    private func key() throws -> SymmetricKey {
        if let fixtureKey{return fixtureKey}
        let query:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"local.mewpon.desktop.private-library",kSecAttrAccount as String:"aes-gcm-v1",kSecAttrSynchronizable as String:false]
        var value:CFTypeRef?
        let result=SecItemCopyMatching(query.merging([kSecReturnData as String:true,kSecMatchLimit as String:kSecMatchLimitOne],uniquingKeysWith:{$1}) as CFDictionary,&value)
        if result==errSecSuccess,let data=value as? Data,data.count==32{return SymmetricKey(data:data)}
        guard result==errSecItemNotFound else{throw MewponError.unavailable("The local library key could not be accessed (\(result)).")}
        let created=SymmetricKey(size:.bits256)
        let data=created.withUnsafeBytes{Data($0)}
        let add=query.merging([kSecValueData as String:data,kSecAttrAccessible as String:kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly],uniquingKeysWith:{$1})
        let status=SecItemAdd(add as CFDictionary,nil)
        guard status==errSecSuccess else{throw MewponError.unavailable("The library encryption key could not be stored (\(status)).")}
        return created
    }
    func save<T:Encodable>(_ value:T,id:UUID,kind:String="meeting") throws {
        let encoder=JSONEncoder();encoder.dateEncodingStrategy = .iso8601
        try saveData(encoder.encode(value),id:id,kind:kind)
    }
    func load<T:Decodable>(_ type:T.Type,id:UUID,kind:String="meeting") throws ->T {
        let decoder=JSONDecoder();decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type,from:loadData(id:id,kind:kind))
    }
    private func location(_ id:UUID,_ kind:String) throws ->URL {
        guard ["meeting","audio","slide","reminders"].contains(kind) else{throw MewponError.invalid("Unsupported private library record.")}
        return root.appendingPathComponent(kind+"-"+id.uuidString+".sealed")
    }
    func saveData(_ data:Data,id:UUID,kind:String) throws {
        guard data.count<=128_000_000 else{throw MewponError.invalid("Record is too large; split the recording first.")}
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let encrypted=try AES.GCM.seal(data,using:key())
        guard let bytes=encrypted.combined else{throw MewponError.unavailable("Encryption did not produce a record.")}
        let url=try location(id,kind)
        try bytes.write(to:url,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
    }
    func loadData(id:UUID,kind:String) throws ->Data {
        let url=try location(id,kind)
        let size=(try url.resourceValues(forKeys:[.fileSizeKey])).fileSize ?? Int.max
        guard size<=128_000_100 else{throw MewponError.invalid("Encrypted record exceeds its size limit.")}
        return try AES.GCM.open(AES.GCM.SealedBox(combined:Data(contentsOf:url)),using:key())
    }
    func meetings() throws ->[MeetingDocument] {
        guard FileManager.default.fileExists(atPath:root.path) else{return []}
        return try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:[.contentModificationDateKey]).filter{$0.lastPathComponent.hasPrefix("meeting-") && $0.pathExtension=="sealed"}.sorted { ((try? $0.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }.prefix(100).compactMap {url in
            guard let id=UUID(uuidString:String(url.deletingPathExtension().lastPathComponent.dropFirst(8))) else{return nil}
            return try load(MeetingDocument.self,id:id)
        }
    }
    func retentionCandidates(days:Int,excluding:UUID?=nil,now:Date = .now)->[UUID] {
        guard (1...3650).contains(days),FileManager.default.fileExists(atPath:root.path) else{return []}
        let cutoff=now.addingTimeInterval(-Double(days)*86400)
        let files=(try? FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:[.contentModificationDateKey])) ?? []
        return files.filter{$0.lastPathComponent.hasPrefix("meeting-") && $0.pathExtension=="sealed"}.compactMap{url -> (UUID,Date)? in
            guard let id=UUID(uuidString:String(url.deletingPathExtension().lastPathComponent.dropFirst(8))),id != excluding,let modified=try? url.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate,modified<cutoff else{return nil}
            return (id,modified)
        }.sorted{$0.1<$1.1}.map{$0.0}
    }
    func applyRetention(days:Int,excluding:UUID?=nil) throws ->(moved:Int,remaining:Int) {
        guard (1...3650).contains(days) else{throw MewponError.invalid("Choose a positive retention period first.")}
        let ids=retentionCandidates(days:days,excluding:excluding)
        var moved=0
        for id in ids.prefix(20) {
            try Task.checkCancellation()
            let document=try load(MeetingDocument.self,id:id)
            for audio in document.audioFiles where FileManager.default.fileExists(atPath:try location(audio,"audio").path){try trash(audio,kind:"audio")}
            for slide in document.slides ?? [] where FileManager.default.fileExists(atPath:try location(slide.id,"slide").path){try trash(slide.id,kind:"slide")}
            try trash(id,kind:"meeting");moved += 1
        }
        return (moved,max(0,ids.count-moved))
    }
    func trash(_ id:UUID,kind:String) throws {var target:NSURL?;try FileManager.default.trashItem(at:location(id,kind),resultingItemURL:&target)}
}
