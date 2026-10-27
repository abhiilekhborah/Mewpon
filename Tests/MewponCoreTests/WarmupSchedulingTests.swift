import AppKit
import XCTest
@testable import MewponCore
@testable import MewponDesktop

private final class WarmupProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    static var paths: [String] = []
    static var unloads=0
    private let lock = NSLock()
    private var stopped = false
    static func reset() { lock.lock(); defer { lock.unlock() }; paths = [];unloads=0 }
    static func unloadCount()->Int{lock.lock();defer{lock.unlock()};return unloads}
    static func count(_ path: String) -> Int { lock.lock(); defer { lock.unlock() }; return paths.filter { $0 == path }.count }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        Self.lock.lock(); Self.paths.append(path); Self.lock.unlock()
        var requestBody = request.httpBody
        if requestBody == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            requestBody = data
        }
        if path=="/api/generate",let data=requestBody,let body=try? JSONSerialization.jsonObject(with:data) as? [String:Any],body["keep_alive"] as? Int==0 {Self.lock.lock();Self.unloads += 1;Self.lock.unlock()}
        let body = path == "/api/tags" ? #"{"models":[{"name":"qwen3:8b"},{"name":"qwen3:4b-instruct"},{"name":"fixture:4b"}]}"# : #"{"done":true}"#
        DispatchQueue.global().asyncAfter(deadline: .now() + (path == "/api/generate" ? 0.2 : 0.01)) { [self] in
            lock.lock(); defer { lock.unlock() }; guard !stopped else { return }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8)); client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { lock.lock(); stopped = true; lock.unlock() }
}

final class WarmupSchedulingTests: XCTestCase {
    @MainActor func testStartupWarmsOnceAndConfigurationChangeRestartsPreparation() async throws {
        _ = NSApplication.shared
        WarmupProtocol.reset()
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [WarmupProtocol.self]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let savedConfiguration = UserDefaults.standard.object(forKey: "modelConfiguration")
        let savedPreload = UserDefaults.standard.object(forKey: "preloadModel")
        UserDefaults.standard.set(try JSONEncoder().encode(ModelConfiguration()), forKey: "modelConfiguration")
        UserDefaults.standard.set(true, forKey: "preloadModel")
        let model = AssistantModel(storageDirectory: root, service: OllamaService(session: URLSession(configuration: config)))
        defer {
            model.shutdown()
            if let savedConfiguration { UserDefaults.standard.set(savedConfiguration, forKey: "modelConfiguration") }
            else { UserDefaults.standard.removeObject(forKey: "modelConfiguration") }
            if let savedPreload { UserDefaults.standard.set(savedPreload, forKey: "preloadModel") }
            else { UserDefaults.standard.removeObject(forKey: "preloadModel") }
            try? FileManager.default.removeItem(at: root)
        }
        guard model.preloadEnabled else { throw XCTSkip("Warm-up disabled in test preferences") }
        let loading = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in WarmupProtocol.count("/api/generate") == 1 }, object: nil)
        await fulfillment(of: [loading], timeout: 2)
        model.schedulePreload(); model.schedulePreload(); model.schedulePreload()
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in model.preloadStatus.hasPrefix("Ready") }, object: nil)
        await fulfillment(of: [ready], timeout: 2)
        XCTAssertEqual(WarmupProtocol.count("/api/generate"), 1)
        XCTAssertEqual(WarmupProtocol.count("/api/chat"), 1)
        model.configuration.model = "fixture:4b"
        let reconfigured = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in model.preloadStatus.hasPrefix("Ready") && WarmupProtocol.count("/api/chat") == 2 }, object: nil)
        await fulfillment(of: [reconfigured], timeout: 2)
        XCTAssertEqual(WarmupProtocol.count("/api/generate")-WarmupProtocol.unloadCount(), 2)
        XCTAssertEqual(WarmupProtocol.unloadCount(),1,"Changing the selected model unloads the previous app-selected model before warming another.")
        model.configuration.keepAliveSeconds = 0
        XCTAssertEqual(model.preloadStatus, "Off")
    }
}
