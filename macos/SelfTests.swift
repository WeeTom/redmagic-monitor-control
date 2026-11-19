import Foundation

private final class FakeDDCTransport:DDCTransport {
    private let lock=NSLock()
    private var state=["luminance":81,"volume":0,"input":7,"contrast":50]
    private var history=[String]()
    var failReads=false
    var blockFirst=false
    let entered=DispatchSemaphore(value:0),release=DispatchSemaphore(value:0)
    private var reads=0
    var events:[String] { lock.lock();defer { lock.unlock() };return history }
    func read(_ feature:String,attempt:Int)->DDCSample {
        lock.lock();reads+=1;let first=reads==1;history.append("get:"+feature)
        let v=state[feature] ?? 0,fail=failReads;lock.unlock()
        if blockFirst && first { entered.signal();_ = release.wait(timeout:.now()+2) }
        return DDCSample(status:fail ? 1:0,value:v,maximum:feature=="volume" ? 65535:100,raw:fail ? "invalid":"validated")
    }
    func write(_ feature:String,value:Int)->Int { lock.lock();defer { lock.unlock() };history.append("set:\(feature):\(value)");state[feature]=value;return 0 }
    func invalidate() {}
}
private func spin(_ seconds:TimeInterval=6,until predicate:()->Bool) {
    let deadline=Date().addingTimeInterval(seconds)
    while !predicate() && Date()<deadline { _=RunLoop.current.run(mode:.default,before:Date().addingTimeInterval(0.01)) }
    precondition(predicate(),"Timed out awaiting test condition")
}
func runSelfTests() {
    for (s,v) in ["0":0,"100":100," 42\n":42] { precondition(DDCController.parse(s)==v) }
    for s in ["101","-1","10 error","","0x10","1\n2","９"] { precondition(DDCController.parse(s)==nil) }
    for value in 0...100 { precondition(DDCController.canWrite("volume",value)) }
    for value in [-1,101,255,65536] { precondition(!DDCController.canWrite("volume",value)) }
    for (feature, code): (String, UInt8) in [("red",0x16),("green",0x18),("blue",0x1a)] {
        precondition(!DDCController.readable.contains(feature) && gm_ddc_can_write(code,50)==0)
    }
    precondition(DDCController.canWrite("input",7) && DDCController.canWrite("input",8))
    precondition(DDCController.inputChoices.map { $0.0 } == [7,8,5,6])
    precondition(Feature.input.choices.map { $0.0 } == [1,2,3,4])
    precondition(DDCController.inputChoices.map { $0.1 } == Feature.input.choices.map { $0.1 })
    for value in 0...255 { precondition(DDCController.canWrite("input",value) == (5...8).contains(value)) }
    precondition(!DDCController.canWrite("reset",1))
    var normal:[UInt8]=[0x6e,0x88,2,0,0x10,0,0,100,0,81,0]
    normal[10]=normal.prefix(10).reduce(UInt8(0x50),^)
    var reply=GMDDCReply()
    precondition(gm_ddc_validate(&normal,11,0x10,0,&reply)==1 && reply.value==81)
    precondition(gm_ddc_validate(&normal,10,0x10,0,&reply)==0)
    precondition(gm_ddc_validate(&normal,11,0x62,0,&reply)==0)
    normal[8]^=1;precondition(gm_ddc_validate(&normal,11,0x10,0,&reply)==0)
    var vendor:[UInt8]=[0x6e,0x89,0xc7,0,0,0x62,0,0,100,0,0,0]
    vendor[11]=vendor.prefix(11).reduce(UInt8(0x50),^)
    precondition(gm_ddc_validate(&vendor,12,0x62,1,&reply)==1 && reply.value==0)
    vendor[3]=1;precondition(gm_ddc_validate(&vendor,12,0x62,1,&reply)==0)
    precondition(DDCController.valid(DDCSample(status:0,value:0,maximum:65535,raw:""),feature:"volume"))
    precondition(!DDCController.valid(DDCSample(status:0,value:101,maximum:65535,raw:""),feature:"volume"))
    precondition(!DDCController.valid(DDCSample(status:0,value:160,maximum:255,raw:""),feature:"luminance"))
    var idle=ConnectionIdlePolicy();idle.activity(at:10)
    precondition(!idle.shouldDisconnect(at:309.99,isBusy:false))
    precondition(idle.shouldDisconnect(at:310,isBusy:false))
    precondition(!idle.shouldDisconnect(at:310,isBusy:true))
    idle.activity(at:300);precondition(!idle.shouldDisconnect(at:310,isBusy:false))
    precondition(gm_value_valid(Feature.volume.rawValue,10,1)==1 && gm_value_valid(Feature.volume.rawValue,11,1)==0)
    precondition(gm_value_valid(Feature.input.rawValue,5,1)==0)

    let fake=FakeDDCTransport();fake.blockFirst=true
    let controller=DDCController(log:EventLog(),transport:fake)
    var results=0,latest:Int?
    controller.read("contrast") { _ in results+=1 }
    precondition(fake.entered.wait(timeout:.now()+1) == .success)
    for v in [20,21,22] { controller.write("luminance",value:v) { r in results+=1;if case .success(let n)=r { latest=n } } }
    fake.release.signal()
    spin { results==4 }
    precondition(latest==22 && fake.events.filter({$0.hasPrefix("set:")})==["set:luminance:22"])
    precondition(fake.events[1]=="set:luminance:22")
    precondition(controller.statistics["coalescedWrites"]==2)
    precondition(controller.statistics["reads"]==3) // One background get + two independent verification gets.

    // Verify the top of the audio range and a read queued immediately after
    // its write. All traffic here goes exclusively to the in-memory transport.
    let audioTransport=FakeDDCTransport()
    audioTransport.blockFirst=true
    let audio=DDCController(log:EventLog(),transport:audioTransport)
    audio.read("contrast") { _ in }
    precondition(audioTransport.entered.wait(timeout:.now()+1) == .success)
    var writeResult:Int?,readResult:Int?
    audio.write("volume",value:100) { writeResult=try? $0.get() }
    audio.read("volume") { readResult=try? $0.get() }
    audioTransport.release.signal()
    spin { writeResult==100 && readResult==100 }
    precondition(audioTransport.events.filter({$0=="get:volume"}).count==2)

    let cache=FileManager.default.temporaryDirectory.appendingPathComponent("gm001j-test-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at:cache) }
    let f=FakeDDCTransport();f.blockFirst=true
    let d=DDCController(log:EventLog(),transport:f)
    let store=DisplayStore(ddc:d,bluetooth:StoreTestBluetooth(),cacheURL:cache,loadCache:false)
    store.ddcValues=["luminance":81,"contrast":50,"volume":0]
    store.refresh()
    precondition(f.entered.wait(timeout:.now()+1) == .success)
    let started=ProcessInfo.processInfo.systemUptime
    for _ in 0..<100 { store.selectChannel(.bluetooth);store.selectChannel(.ddc) }
    let channelSeconds=ProcessInfo.processInfo.systemUptime-started
    precondition(channelSeconds<0.2 && f.events.count==1)
    store.setDDC("luminance",80);store.setDDC("luminance",79)
    precondition(store.displayedDDC("luminance")==79)
    f.release.signal();spin { !store.busy }
    precondition(store.ddcValues["luminance"]==79 && store.ddcDrafts["luminance"]==nil)
    precondition(f.events.filter({$0.hasPrefix("set:")})==["set:luminance:79"])
    let before=f.events.count
    for _ in 0..<20 { store.selectChannel(.bluetooth);store.selectChannel(.ddc) }
    precondition(f.events.count==before)
    f.failReads=true;store.refresh();spin { !store.busy }
    precondition(store.ddcValues["luminance"]==79 && store.displayedDDC("luminance")==79)
    precondition(store.noteDDC("luminance")=="上次确认")
    store.setDDC("luminance",78);spin { !store.busy }
    precondition(store.ddcValues["luminance"]==79 && store.displayedDDC("luminance")==78 && store.noteDDC("luminance")=="待确认")
    spin { FileManager.default.fileExists(atPath:cache.path) }
    let restored=DisplayStore(ddc:d,cacheURL:cache)
    precondition(restored.channel == .ddc && restored.ddcValues["luminance"]==79 && restored.ddcDrafts.isEmpty)
    f.failReads=false
    let savedCount=f.events.count
    restored.start();spin { !restored.busy }
    precondition(f.events.count>savedCount && f.events.dropFirst(savedCount).allSatisfy { $0.hasPrefix("get:") })
    for input in DDCController.inputChoices where [5,6].contains(input.0) {
        restored.setDDC("input",input.0)
        spin { !restored.busy }
        precondition(restored.ddcValues["input"]==input.0 && restored.ddcDrafts["input"]==nil)
        precondition(f.events.contains("set:input:\(input.0)"))
    }
    print("PASS: both HDMI buttons route to the matching DDC input and verify its readback (simulated monitor)")
    runStoreActivationTests()
    print("PASS: strict standard/vendor DDC frames, DDC volume 0–100, RGB controls removed, 300s idle boundary")
    print("PASS: latest write wins, read preemption, two independent readbacks, stale callbacks ignored")
    print("PASS: cached values survive failures; unconfirmed targets are not persisted; 200 page switches \(Int(channelSeconds*1000)) ms while a background read was pending")
}
