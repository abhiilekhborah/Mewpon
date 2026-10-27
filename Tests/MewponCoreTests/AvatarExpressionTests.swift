import AppKit
import Combine
import WebKit
import XCTest
@testable import MewponDesktop

final class AvatarExpressionTests: XCTestCase {
    @MainActor func testStableCharacterFacialMorphAndCleanExteriorOnLightAndDark() async throws {
        _ = NSApplication.shared
        let bridge = AvatarBridge()
        let window = NSWindow(contentRect: NSRect(x: 40, y: 170, width: 300, height: 240), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = bridge.webView; window.orderFront(nil)
        defer { window.orderOut(nil); window.close() }
        let ready = expectation(description: "Avatar loaded")
        let token = bridge.$isReady.filter { $0 }.prefix(1).sink { _ in ready.fulfill() }
        defer { token.cancel() }
        await fulfillment(of: [ready], timeout: 20)
        guard bridge.isReady else { return }
        func script(_ code: String, _ args: [String: Any] = [:]) async throws -> Any? {
            try await bridge.webView.callAsyncJavaScript(code, arguments: args, in: nil, contentWorld: .page)
        }
        let result = try await script("""
            nativeAvatar.budget(30);if(mewpon.maxFps!==30)throw new Error('Inference budget missing');nativeAvatar.budget(60);if(mewpon.maxFps!==60)throw new Error('Full budget not restored');
            mewpon.stop();mewpon.reset();mewpon.autoBlink=false;mewpon.idleGlance=false;mewpon.enableAutonomousIdle(false);
            const heads=new Map(MewponLib.EXPRESSIONS.map(name=>[mewpon.assets.pixelSource(mewpon.assets.manifest.groups.expressions[name].head),name]));
            const bodies=new Map(MewponLib.EXPRESSIONS.map(name=>[mewpon.assets.pixelSource(mewpon.assets.manifest.groups.expressions[name].body),name]));
            const headFiles=new Map(MewponLib.EXPRESSIONS.map(name=>[mewpon.assets.manifest.groups.expressions[name].head.file,name]));
            const bodyFiles=new Map(MewponLib.EXPRESSIONS.map(name=>[mewpon.assets.manifest.groups.expressions[name].body.file,name]));
            const original=CanvasRenderingContext2D.prototype.drawImage;
            let seen=new Set(),seenBodies=new Set(),checked=0;
            CanvasRenderingContext2D.prototype.drawImage=function(source,...args){if(heads.has(source))seen.add(heads.get(source));if(bodies.has(source))seenBodies.add(bodies.get(source));const key=source.dataset?.mewponTexture;if(headFiles.has(key))seen.add(headFiles.get(key));if(bodyFiles.has(key))seenBodies.add(bodyFiles.get(key));return original.call(this,source,...args);};
            try{
              for(const name of MewponLib.EXPRESSIONS){
                mewpon.setExpression(name);
                for(const dt of [0.001,0.03,0.08,0.2]){
                  seen.clear();seenBodies.clear();mewpon.advance(dt,0.05);
                  if(seen.size!==1||!seen.has('neutral'))throw new Error('Character head swapped during expression: '+name+' '+[...seen]);
                  if(seenBodies.size!==1||!seenBodies.has('neutral'))throw new Error('Character body swapped during expression: '+name+' '+[...seenBodies]);
                  checked++;
                }
              }
            }finally{CanvasRenderingContext2D.prototype.drawImage=original;}
            mewpon.reset();mewpon.enableAutonomousIdle(false);
            const order=[];const off=mewpon.on('expressionChanged',e=>order.push(e.to));
            mewpon.react('click');
            if(mewpon.getExpression()!=='surprised')throw new Error('Surprise skipped');
            mewpon.advance(0.44);if(mewpon.getExpression()!=='surprised')throw new Error('Surprise ended early');
            mewpon.advance(0.02);if(mewpon.getExpression()!=='happy')throw new Error('Happy stage missing');
            mewpon.advance(1.31);if(mewpon.getExpression()!=='neutral')throw new Error('Reaction did not return');
            mewpon.react('click');mewpon.setExpression('focused');mewpon.advance(2);
            if(mewpon.getExpression()!=='focused')throw new Error('Stale reaction overrode selection');
            off();if(order.slice(0,3).join(',')!=='surprised,happy,neutral')throw new Error('Reaction order '+order);
            const l=mewpon.assets.manifest.groups.expressions.neutral.full,img=mewpon.assets.img(l),clean=mewpon.assets.pixelSource(l);
            const c=document.createElement('canvas');c.width=l.w;c.height=l.h;const ctx=c.getContext('2d');
            ctx.drawImage(img,0,0);const before=ctx.getImageData(0,0,c.width,c.height).data;
            ctx.clearRect(0,0,c.width,c.height);ctx.drawImage(clean,0,0);const after=ctx.getImageData(0,0,c.width,c.height).data;
            let removed=0,promoted=0;for(let i=3;i<before.length;i+=4){if(before[i]>16&&after[i]===0)removed++;if(after[i]>before[i]+1)promoted++;}
            if(removed===0||promoted!==0)throw new Error('Exterior cleanup failed '+JSON.stringify({removed,promoted}));
            const e=mewpon.assets.manifest.groups.expressions.neutral,h=e.head;
            c.width=h.w;c.height=h.h;ctx.drawImage(mewpon.assets.pixelSource(h),0,0);const head=ctx.getImageData(0,0,c.width,c.height).data;
            for(let y=0;y<h.h;y++)for(let x=0;x<h.w;x++)if(x+h.ox>=e.sprout.ox-3&&x+h.ox<e.sprout.ox+e.sprout.w+3&&y+h.oy<e.domeY&&head[(y*h.w+x)*4+3]!==0)throw new Error('Baked sprout contour remains in head');
            return {checked,removed,promoted};
            """) as? [String: Any]
        XCTAssertEqual(result?["checked"] as? Int, 56)
        XCTAssertGreaterThan(result?["removed"] as? Int ?? 0, 0)
        XCTAssertEqual(result?["promoted"] as? Int, 0)
        let destination = ProcessInfo.processInfo.environment["MEWPON_VERIFICATION_DIR"].map { URL(fileURLWithPath: $0).appendingPathComponent("Expressions") }
        if let destination { try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true) }
        for background in ["light", "dark"] {
            for expression in ["neutral", "happy", "excited", "thinking", "confused", "sad", "angry", "sleepy", "wink", "laugh", "surprised", "embarrassed", "proud", "focused"] {
                _ = try await script("mewpon.reset();mewpon.enableAutonomousIdle(false);mewpon.setTransparent(false);mewpon.setBackground(background==='dark'?'#18283c':'#edf2f8');mewpon.setExpression(expression);mewpon.advance(0.5,1/60);", ["background": background, "expression": expression])
                let image = try await bridge.webView.takeSnapshot(configuration: nil)
                if let destination, let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try png.write(to: destination.appendingPathComponent(background + "-" + expression + ".png"))
                }
            }
        }
        if let destination {
            for expression in ["neutral", "happy", "sad", "surprised"] {
                _ = try await script("mewpon.reset();mewpon.enableAutonomousIdle(false);mewpon.setOutfit('summer');mewpon.setExpression(expression);mewpon.advance(0.5);", ["expression": expression])
                let image = try await bridge.webView.takeSnapshot(configuration: nil)
                if let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) { try png.write(to: destination.appendingPathComponent("summer-" + expression + ".png")) }
            }
        }
        if let destination {
            let frames = destination.appendingPathComponent("Motion")
            try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
            _ = try await script("mewpon.reset();mewpon.enableAutonomousIdle(false);mewpon.setTransparent(false);mewpon.setBackground('#18283c');")
            for index in 0..<180 {
                let expression = ["neutral", "happy", "confused", "angry", "sleepy", "neutral"][index / 30]
                let encoded = try await script("mewpon.setExpression(expression);mewpon.advance(1/30);return mewpon.canvas.toDataURL('image/png').split(',')[1];", ["expression": expression]) as? String
                if let encoded, let data = Data(base64Encoded: encoded) { try data.write(to: frames.appendingPathComponent(String(format: "%03d.png", index))) }
            }
        }
    }
}
