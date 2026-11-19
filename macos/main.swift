import AppKit
import SwiftUI
import Darwin

let args=CommandLine.arguments
if args.contains("--self-test") {
    runSelfTests()
    exit(0)
}

final class AppDelegate:NSObject,NSApplicationDelegate {
    var statusItem:NSStatusItem!
    let popover=NSPopover()
    var store:DisplayStore!
    var lockFD:Int32 = -1
    let showNotification=Notification.Name("com.local.redmagic-display.show")
    func applicationDidFinishLaunching(_ notification:Notification) {
        NSApp.setActivationPolicy(.accessory)
        if let i=args.firstIndex(of:"--preview"),args.count>i+1 {
            store=DisplayStore(demo:true)
            if args.contains("--preview-bluetooth") { store.channel = .bluetooth }
            if args.contains("--preview-light") { NSApp.appearance = NSAppearance(named: .aqua) }
            if args.contains("--preview-dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
            // Reproduce a cached BLE page followed by DDC values arriving after mount.
            let simulatesFirstRead = args.contains("--preview-cold-ddc")
            if simulatesFirstRead { store.channel = .bluetooth; store.ddcValues = [:] }
            let view=NSHostingView(rootView:ControlPanel(store:store))
            let window=NSWindow(contentRect:NSRect(origin:.zero,size:PanelLayout.size(for:store.channel)),styleMask:[.borderless],backing:.buffered,defer:false)
            window.contentView=view;window.orderFront(nil);view.layoutSubtreeIfNeeded()
            if simulatesFirstRead {
                DispatchQueue.main.asyncAfter(deadline:.now()+0.15) {
                    self.store.selectChannel(.ddc)
                    window.setContentSize(PanelLayout.size(for: .ddc))
                }
                DispatchQueue.main.asyncAfter(deadline:.now()+0.4) {
                    self.store.ddcValues = ["input": 7, "luminance": 50, "contrast": 50, "volume": 20]
                }
            }
            DispatchQueue.main.asyncAfter(deadline:.now()+0.8) {
                guard let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds) else { exit(1) }
                view.cacheDisplay(in:view.bounds,to:bitmap)
                guard let data=bitmap.representation(using:.png,properties:[:]) else { exit(1) }
                do { try data.write(to:URL(fileURLWithPath:args[i+1]));exit(0) } catch { fputs("\(error)\n",stderr);exit(1) }
            };return
        }
        let cache=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/com.local.redmagic-display",isDirectory:true)
        try? FileManager.default.createDirectory(at:cache,withIntermediateDirectories:true)
        lockFD=open(cache.appendingPathComponent("app.lock").path,O_CREAT|O_RDWR,0o600)
        guard lockFD>=0,flock(lockFD,LOCK_EX|LOCK_NB)==0 else {
            DistributedNotificationCenter.default().postNotificationName(showNotification,object:nil,userInfo:nil,deliverImmediately:true)
            NSApp.terminate(nil);return
        }
        let isProbe = args.contains("--probe") || args.contains("--probe-keepalive")
        store=DisplayStore(channelDefaults: isProbe ? nil : .standard)
        if isProbe {
            let keepalive=args.contains("--probe-keepalive")
            if keepalive { store.channel = .bluetooth }
            var rounds=0
            var inputs=[Int]()
            store.onRefreshComplete={ [weak self] in
                guard let self,!self.store.busy else { return }
                rounds+=1
                inputs.append(self.store.values[.input] ?? -1)
                if keepalive && rounds==1 {
                    DispatchQueue.main.asyncAfter(deadline:.now()+7) { self.store.refresh() };return
                }
                if keepalive {
                    let report:[String:Any]=["rounds":rounds,"gapSeconds":7,"connectionCount":self.store.bluetooth.connectionCount,"idleDisconnectSeconds":300,"sameConnectionReused":self.store.bluetooth.connectionCount==1 && inputs.count==2 && inputs.allSatisfy({$0>=0}),"inputReplies":inputs,"operation":"read-only capability queries","settingWrites":self.store.bluetooth.settingWriteCount,"queryWrites":self.store.bluetooth.queryWriteCount]
                    if let data=try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]) {
                        try? data.write(to:self.store.log.directory.appendingPathComponent("connection-test.json"),options:.atomic)
                        print(String(data:data,encoding:.utf8)!)
                    }
                }
                print("Read-only probe finished; results: \(self.store.statusURL.path)")
                NSApp.terminate(nil)
            }
            DispatchQueue.main.asyncAfter(deadline:.now()+75) { NSApp.terminate(nil) }
            store.refresh();return
        }
        statusItem=NSStatusBar.system.statusItem(withLength:NSStatusItem.squareLength)
        if let button=statusItem.button {
            button.image=NSImage(systemSymbolName:"display",accessibilityDescription:"红魔显示器控制")
            button.title=""
            button.image?.isTemplate=true;button.target=self;button.action=#selector(clicked)
            button.sendAction(on:[.leftMouseUp,.rightMouseUp]);button.toolTip="红魔显示器 · 输入源与画面控制"
        }
        popover.behavior = .transient
        popover.contentSize=PanelLayout.size(for:store.channel)
        popover.contentViewController=NSHostingController(rootView:ControlPanel(store:store))
        store.onChange={ [weak self] in
            guard let self else { return }
            let size=PanelLayout.size(for:self.store.channel)
            if self.popover.contentSize != size { self.popover.contentSize=size }
        }
        DistributedNotificationCenter.default().addObserver(self,selector:#selector(show),name:showNotification,object:nil)
        NSWorkspace.shared.notificationCenter.addObserver(self,selector:#selector(sleeping),name:NSWorkspace.willSleepNotification,object:nil)
        NSWorkspace.shared.notificationCenter.addObserver(self,selector:#selector(woke),name:NSWorkspace.didWakeNotification,object:nil)
        store.start()
        DispatchQueue.main.asyncAfter(deadline:.now()+0.7) { [weak self] in self?.show() }
    }
    @objc func clicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu=NSMenu()
            menu.addItem(withTitle:"打开红魔显示器",action:#selector(show),keyEquivalent:"").target=self
            menu.addItem(withTitle:"刷新设置",action:#selector(refresh),keyEquivalent:"").target=self
            menu.addItem(.separator());menu.addItem(withTitle:"退出",action:#selector(quit),keyEquivalent:"q").target=self
            statusItem.menu=menu;statusItem.button?.performClick(nil);statusItem.menu=nil
        } else if popover.isShown { popover.performClose(nil) } else { show() }
    }
    @objc func show() {
        guard let button=statusItem?.button else { return }
        NSApp.activate(ignoringOtherApps:true)
        let opening = !popover.isShown
        popover.show(relativeTo:button.bounds,of:button,preferredEdge:.minY)
        if opening { store.panelOpened() }
    }
    @objc func refresh() { store.refresh() }
    @objc func quit() { NSApp.terminate(nil) }
    @objc func sleeping() { store.stop() }
    @objc func woke() { DispatchQueue.main.asyncAfter(deadline:.now()+2) { [weak self] in self?.store.refresh() } }
    func applicationWillTerminate(_ notification:Notification) {
        store?.onRefreshComplete=nil;store?.stop()
        if lockFD>=0 { close(lockFD) }
    }
}
let application=NSApplication.shared
let delegate=AppDelegate();application.delegate=delegate;application.run()
