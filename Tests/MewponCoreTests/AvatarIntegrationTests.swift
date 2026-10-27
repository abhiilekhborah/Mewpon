import AppKit
import Combine
import WebKit
import XCTest
@testable import MewponCore
@testable import MewponDesktop

final class AvatarIntegrationTests: XCTestCase {
    @MainActor func testRealWebKitRigCatalogSnapshotsAndPerformance() async throws {
        _ = NSApplication.shared
        let bridge = AvatarBridge()
        let window = NSWindow(contentRect: NSRect(x: 30, y: 160, width: 300, height: 240), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.backgroundColor = .clear; window.isOpaque = false
        window.contentView = bridge.webView; window.orderFront(nil)
        defer { window.orderOut(nil); window.close() }
        let ready = expectation(description: "Original textures and updated engine loaded in WKWebView")
        let token = bridge.$isReady.filter { $0 }.prefix(1).sink { _ in ready.fulfill() }
        defer { token.cancel() }
        await fulfillment(of: [ready], timeout: 20)
        guard bridge.isReady else { return }
        XCTAssertNil(bridge.error)
        func script(_ code: String, _ args: [String: Any] = [:]) async throws -> Any? {
            try await bridge.webView.callAsyncJavaScript(code, arguments: args, in: nil, contentWorld: .page)
        }
        _ = try await script("mewpon.stop(); mewpon.autoBlink=false; mewpon.idleGlance=false;")
        let audit = try await script("""
            let checked=0,maxShift=0;
            for(const outfit of MewponLib.OUTFITS){
              mewpon.reset();mewpon.setOutfit(outfit);mewpon.advance(0.3);
              for(const expression of MewponLib.EXPRESSIONS){
                mewpon.setExpression(expression);mewpon.advance(0.15);
                if(mewpon.getOutfit()!==outfit)throw new Error('Outfit reset');
                if(!Object.values(mewpon.renderer.hitBox).every(Number.isFinite))throw new Error('Invalid bounds');
                checked++;
              }
              for(const activity of MewponLib.ACTIVITIES){mewpon.transitionTo({activity,expression:'focused'});mewpon.advance(0.3);if(mewpon.getActivity()!==activity)throw new Error('Activity rejected');}
            }
            mewpon.reset();
            for(let i=0;i<50;i++){mewpon.transitionTo({activity:i%2?'searching':'typing',expression:i%2?'thinking':'focused'});mewpon.advance(0.03);}
            return {checked};
            """) as? [String: Any]
        XCTAssertEqual(audit?["checked"] as? Int, 140)

        let petAudit = try await script("""
            mewpon.reset();mewpon.enableAutonomousIdle(false);
            if(!mewpon.enterPlayMode())throw new Error('Play rejected while idle');
            mewpon.setOutfit('wizard');mewpon.setExpression('proud');mewpon.advance(35);
            if(mewpon.getExpression()!=='proud')throw new Error('Selected expression interrupted');
            mewpon.interact('nap');mewpon.advance(20);
            if(mewpon.getPetState().action!=='nap'||mewpon.getOutfit()!=='wizard')throw new Error('Nap changed outfit preference');
            mewpon.interact('highFive');mewpon.advance(0.5);
            if(!mewpon.hitHighFive()||mewpon.getPetState().action!=='dance')throw new Error('High five missed');
            mewpon.setAssistantState('thinking',null,true);
            if(mewpon.isInPlayMode()||mewpon.interact('dance')||mewpon.enterPlayMode())throw new Error('Pet preempted assistant');
            mewpon.setAssistantState('neutral',null,false);mewpon.enterPlayMode();mewpon.exitPlayMode();
            if(mewpon.getExpression()!=='neutral'||mewpon.getOutfit()!=='wizard')throw new Error('Exit restore failed');
            let pixelChecks=0;
            for(const scale of [0.75,1,1.25,1.5]){
              const ratio=window.devicePixelRatio;mewpon.setScale(scale);
              mewpon.reset();mewpon.enableAutonomousIdle(false);mewpon.advance(0.2);
              const unit=mewpon.renderer.unit,c=mewpon.canvas,ctx=c.getContext('2d');
              if(unit!==Math.floor(unit)||ctx.imageSmoothingEnabled)throw new Error('Fractional pixel sampling');
              if(c.width!==Math.round(mewpon.renderer.cw*ratio)||c.height!==Math.round(mewpon.renderer.ch*ratio))throw new Error('Wrong backing resolution '+JSON.stringify({ratio,w:c.width,h:c.height,cw:mewpon.renderer.cw,ch:mewpon.renderer.ch,dpr:mewpon.renderer.dpr}));
              const data=ctx.getImageData(0,0,c.width,c.height).data;
              for(let y=0;y<c.height;y++)for(let x=0;x<c.width;x++){
                const a=(y*c.width+x)*4,b=(Math.floor(y/unit)*unit*c.width+Math.floor(x/unit)*unit)*4;
                for(let ch=0;ch<4;ch++)if(data[a+ch]!==data[b+ch])throw new Error('Blur inside logical pixel');
              }
              pixelChecks++;
            }
            mewpon.setScale(1.25);
            return {pixelChecks};
            """) as? [String: Any]
        XCTAssertEqual(petAudit?["pixelChecks"] as? Int, 4)

        let destination = ProcessInfo.processInfo.environment["MEWPON_VERIFICATION_DIR"].map { URL(fileURLWithPath: $0).appendingPathComponent("Avatar") }
        if let destination { try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true) }
        let scenes: [(String, String)] = [
            ("default-idle", "mewpon.reset();mewpon.advance(1);"),
            ("typing", "mewpon.reset();mewpon.setActivity('typing');mewpon.advance(0.48);"),
            ("searching", "mewpon.reset();mewpon.setActivity('searching');mewpon.advance(0.7);"),
            ("listening", "mewpon.reset();mewpon.setActivity('listening');mewpon.advance(0.7);"),
            ("thinking", "mewpon.reset();mewpon.setExpression('thinking');mewpon.advance(1);"),
            ("jump", "mewpon.reset();mewpon.playAnimation('jump',{duration:1});mewpon.advance(0.48);")
        ] + AvatarMapping.outfits.map { ("outfit-" + $0, "mewpon.reset();mewpon.setOutfit('\($0)');mewpon.advance(1);") }
          + ["pet", "poke", "highFive", "wave", "dance", "spin", "followCursor", "nap", "wake", "random"].map { ("play-" + $0, "mewpon.reset();mewpon.enableAutonomousIdle(false);mewpon.enterPlayMode();mewpon.interact('\($0)');mewpon.lookAtNormalized(0.7,-0.3);mewpon.advance(0.8);") }
          + ["reading", "writing", "drinking", "cooking", "sleeping"].map { ("activity-" + $0, "mewpon.reset();mewpon.setActivity('\($0)');mewpon.advance(1.4);") }
        for (name, code) in scenes {
            _ = try await script(code)
            let image = try await bridge.webView.takeSnapshot(configuration: nil)
            XCTAssertGreaterThan(image.size.width, 0)
            if let destination, let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try png.write(to: destination.appendingPathComponent(name + ".png"))
            }
        }
        let performance = try await script("""
            mewpon.reset();mewpon.autoBlink=true;mewpon.setActivity('searching');mewpon.start();mewpon.start();
            const before=mewpon.getPerformance().totalDraws,start=performance.now();
            await new Promise(resolve=>setTimeout(resolve,2200));
            const result=mewpon.getPerformance();result.observedFPS=(result.totalDraws-before)/((performance.now()-start)/1000);result.visibility=document.visibilityState;
            return result;
            """) as? [String: Any]
        XCTAssertEqual(performance?["loops"] as? Int, 1)
        XCTAssertGreaterThan(performance?["samples"] as? Int ?? 0, 0)
        if let performance, let destination {
            let data = try JSONSerialization.data(withJSONObject: performance, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: destination.appendingPathComponent("performance.json"))
            print("Measured WebKit avatar performance: " + String(decoding: data, as: UTF8.self))
        }
        _ = try await script("mewpon.stop();")
    }
}
