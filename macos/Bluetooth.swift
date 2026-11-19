import Foundation
import CoreBluetooth

final class BluetoothController:NSObject,CBCentralManagerDelegate,CBPeripheralDelegate {
    struct Job {
        let feature:Feature
        let desired:Int?
        let reapply:Bool
        let completion:(Result<Int,Error>)->Void
    }
    let service=CBUUID(string:"0000E0FF-3C17-D293-8E48-14FE2E4DA212")
    let identityService=CBUUID(string:"0000D0FF-3C17-D293-8E48-14FE2E4DA212")
    private let expectedMAC = MonitorIdentity.address
    private var peripheralKey: String { "verifiedPeripheral." + (MonitorIdentity.addressSuffix ?? "") }
    let log:EventLog
    var onState:((String)->Void)?
    var onConnection:((Bool)->Void)?
    private(set) var connectionCount=0
    private(set) var settingWriteCount=0
    private(set) var queryWriteCount=0
    private var central:CBCentralManager!
    private var peripheral:CBPeripheral?
    private var tx:CBCharacteristic?
    private var rx:CBCharacteristic?
    private var identity:CBCharacteristic?
    private var discovery=Set<String>()
    private var pending=[Job]()
    private var active:Job?
    private var machine=GMState()
    private var decoder=GMDecoder()
    private var machineStarted=false
    private var stage="idle"
    private var deadline:TimeInterval=0
    private var timer:Timer?
    private var idlePolicy=ConnectionIdlePolicy()
    private var connectionAttempt=0
    private var verified=false
    private var expectedDisconnect=false
    private var readyAt:TimeInterval=0
    var isBusy:Bool { active != nil || !pending.isEmpty }
    private var clock:TimeInterval { ProcessInfo.processInfo.systemUptime }
    private var ms:UInt64 { UInt64(clock*1000) }
    init(log:EventLog) {
        self.log=log;super.init()
        central=CBCentralManager(delegate:self,queue:.main,options:[CBCentralManagerOptionShowPowerAlertKey:false])
        timer=Timer.scheduledTimer(withTimeInterval:0.1,repeats:true) { [weak self] _ in self?.tick() }
    }
    func submit(_ feature:Feature,value:Int?=nil,reapply:Bool=false,completion:@escaping(Result<Int,Error>)->Void) {
        guard expectedMAC != nil else {
            completion(.failure(DisplayError("请配置显示器 BluetoothAddress 并重启应用"))); return
        }
        if let value,gm_value_valid(feature.rawValue,Int32(value),1)==0 {
            completion(.failure(DisplayError("该设置值不受支持")));return
        }
        if value != nil {
            let replaced=pending.filter { $0.feature==feature && $0.desired != nil }
            pending.removeAll { $0.feature==feature && $0.desired != nil }
            for old in replaced { old.completion(.failure(DDCOperationError.superseded)) }
        }
        guard pending.count<24 else { completion(.failure(DisplayError("操作较多，请稍候再试")));return }
        let job=Job(feature:feature,desired:value,reapply:reapply,completion:completion)
        if value != nil { pending.insert(job,at:0) } else { pending.append(job) }
        idlePolicy.activity(at:clock)
        startNext()
    }
    private func startNext() {
        guard active==nil,!pending.isEmpty else { return }
        active=pending.removeFirst();machineStarted=false;connectionAttempt=0
        if stage=="ready" { beginProtocol() }
        else if !["connecting","discovering","identity","subscribing","scanning","permission"].contains(stage) { beginConnection() }
    }
    private func beginConnection() {
        guard active != nil else { return }
        if peripheral?.state == .disconnecting { stage="disconnecting";deadline=clock+5;return }
        guard central.state == .poweredOn else {
            stage="permission";deadline=clock+45
            if central.state == .poweredOff { failAll("Mac 蓝牙已关闭，请开启后刷新") }
            else if central.state == .unauthorized && CBManager.authorization != .notDetermined { failAll("请在系统设置 → 隐私与安全性 → 蓝牙中允许本应用") }
            else { onState?("等待蓝牙授权…") }
            return
        }
        verified=false;tx=nil;rx=nil;identity=nil;gm_decoder_reset(&decoder)
        let saved=UserDefaults.standard.string(forKey:peripheralKey).flatMap(UUID.init(uuidString:))
        if let saved, let cached=central.retrievePeripherals(withIdentifiers:[saved]).first { connect(cached) }
        else { scan() }
    }
    private func scan() {
        stage="scanning";deadline=clock+12;onState?("正在寻找显示器…")
        central.scanForPeripherals(withServices:[service],options:nil)
    }
    private func connect(_ p:CBPeripheral) {
        central.stopScan();peripheral=p;p.delegate=self
        stage="connecting";deadline=clock+15;onState?("正在连接显示器…")
        central.connect(p,options:nil)
    }
    private func beginProtocol() {
        guard let job=active,verified,stage=="ready" else { return }
        if !machineStarted {
            _=gm_init_feature(&machine,job.feature.rawValue,Int32(job.desired ?? -1),job.reapply ? 1:0,ms)
            machineStarted=true
        }
        onState?(job.desired==nil ? "正在读取\(job.feature.title)…" : "正在设置\(job.feature.title)…")
    }
    private func tick() {
        if stage=="ready",idlePolicy.shouldDisconnect(at:clock,isBusy:isBusy) {
            stage="idle";verified=false;expectedDisconnect=true
            onConnection?(false);onState?("空闲 5 分钟，蓝牙已断开")
            if let p=peripheral { central.cancelPeripheralConnection(p) }
        }
        if active != nil,stage != "ready",deadline>0,clock>=deadline { failAll("连接超时。请检查显示器蓝牙，或暂时断开头玩 App 后刷新");return }
        guard active != nil,stage=="ready",machineStarted,clock>=readyAt else { return }
        guard let p=peripheral,let tx,verified else { failAll("蓝牙连接尚未就绪");return }
        if p.canSendWriteWithoutResponse || ms>=machine.expires {
            var bytes=[UInt8](repeating:0,count:3)
            if gm_poll(&machine,ms,&bytes)==1 {
                if [UInt8(0xec),0xed,0xee].contains(bytes[0]) { settingWriteCount+=1 } else { queryWriteCount+=1 }
                gm_decoder_reset(&decoder)
                log.record("ble_write",["bytes":bytes.map { String(format:"%02x",$0) }.joined(),"feature":active!.feature.title])
                p.writeValue(Data(bytes),for:tx,type:.withoutResponse)
            }
        }
        if gm_finished(&machine) != 0 { endProtocol() }
    }
    private func endProtocol() {
        guard let job=active else { return }
        let result=machine.result
        log.record("ble_result",["feature":job.feature.title,"result":String(cString:gm_result_name(&machine)),"before":machine.before,"after":machine.after,"setWrites":machine.set_writes,"queryWrites":machine.query_writes,"osdVisuallyVerified":false,"usbIndependentlyVerified":false])
        active=nil;machineStarted=false;gm_decoder_reset(&decoder)
        if result>0 { job.completion(.success(Int(machine.after))) }
        else { job.completion(.failure(DisplayError(job.feature == .volume ? "当前固件未响应音量接口" : "\(job.feature.title)未能通过回读确认，请刷新检查"))) }
        idlePolicy.activity(at:clock);readyAt=clock+0.35
        startNext()
    }
    private func failAll(_ text:String) {
        log.record("ble_error",["message":text,"stage":stage])
        let jobs=([active].compactMap { $0 })+pending;active=nil;pending.removeAll();machineStarted=false
        stage="idle";verified=false;central.stopScan();gm_decoder_reset(&decoder)
        onConnection?(false)
        if let p=peripheral,p.state != .disconnected { expectedDisconnect=true;central.cancelPeripheralConnection(p) }
        onState?(text)
        for job in jobs { job.completion(.failure(DisplayError(text))) }
    }
    func stop() {
        failAll("蓝牙已断开，可刷新重新连接")
    }
    func centralManagerDidUpdateState(_ central:CBCentralManager) {
        log.record("ble_state",["state":central.state.rawValue,"authorization":CBManager.authorization.rawValue])
        if central.state == .poweredOn,active != nil { beginConnection() }
        else if central.state == .poweredOff,isBusy { failAll("Mac 蓝牙已关闭") }
        else if central.state == .unauthorized,CBManager.authorization != .notDetermined,isBusy { failAll("请在系统设置 → 隐私与安全性 → 蓝牙中允许本应用") }
    }
    func centralManager(_ central:CBCentralManager,didDiscover p:CBPeripheral,advertisementData:[String:Any],rssi:NSNumber) {
        guard stage=="scanning" else { return }
        let name=advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? p.name
        if let suffix = MonitorIdentity.addressSuffix, name?.uppercased() == "REDMAGIC GM001J" + suffix { connect(p) } // MAC in FFD2 is still mandatory before any command.
    }
    func centralManager(_ central:CBCentralManager,didConnect p:CBPeripheral) {
        guard p===peripheral,active != nil else { central.cancelPeripheralConnection(p);return }
        connectionCount+=1;log.record("ble_connected",["connectionCount":connectionCount])
        stage="discovering";deadline=clock+10;p.discoverServices([service,identityService])
    }
    func centralManager(_ central:CBCentralManager,didFailToConnect p:CBPeripheral,error:Error?) {
        guard p===peripheral,active != nil else { return }
        if connectionAttempt==0 { connectionAttempt=1;scan() } else { failAll("无法连接显示器蓝牙") }
    }
    func centralManager(_ central:CBCentralManager,didDisconnectPeripheral p:CBPeripheral,error:Error?) {
        guard p===peripheral else { return }
        if expectedDisconnect || stage=="disconnecting" {
            expectedDisconnect=false;verified=false;stage="idle"
            onConnection?(false)
            if active != nil { beginConnection() };return
        }
        let wasActive=active != nil;verified=false;gm_decoder_reset(&decoder)
        onConnection?(false)
        if !wasActive { stage="idle";return }
        if machineStarted,gm_reconnect(&machine,ms)==1 {
            log.record("ble_reconnect_verification_only",["setWrites":machine.set_writes]);stage="idle";beginConnection()
        } else { failAll("显示器蓝牙已断开，请刷新；已发送的设置不会自动重复发送") }
    }
    func peripheral(_ p:CBPeripheral,didDiscoverServices error:Error?) {
        guard p===peripheral,stage=="discovering" else { return }
        guard error==nil,let services=p.services,services.contains(where:{$0.uuid==service}),services.contains(where:{$0.uuid==identityService}) else { failAll("显示器缺少所需的蓝牙服务");return }
        let required=services.filter { $0.uuid==service || $0.uuid==identityService }
        discovery=Set(required.map { $0.uuid.uuidString })
        for s in required { p.discoverCharacteristics(s.uuid==service ? [CBUUID(string:"FFE1"),CBUUID(string:"FFE2")] : [CBUUID(string:"FFD2")],for:s) }
    }
    func peripheral(_ p:CBPeripheral,didDiscoverCharacteristicsFor s:CBService,error:Error?) {
        guard p===peripheral,stage=="discovering" else { return }
        guard error==nil else { failAll("读取蓝牙特征失败");return }
        for c in s.characteristics ?? [] {
            if s.uuid==service,c.uuid==CBUUID(string:"FFE1") { tx=c }
            if s.uuid==service,c.uuid==CBUUID(string:"FFE2") { rx=c }
            if s.uuid==identityService,c.uuid==CBUUID(string:"FFD2") { identity=c }
        }
        discovery.remove(s.uuid.uuidString)
        if discovery.isEmpty {
            guard let tx,tx.properties.contains(.writeWithoutResponse),let rx,rx.properties.contains(.notify),let identity,identity.properties.contains(.read) else { failAll("显示器蓝牙接口与已验证协议不一致");return }
            stage="identity";deadline=clock+5;p.readValue(for:identity)
        }
    }
    func peripheral(_ p:CBPeripheral,didUpdateNotificationStateFor c:CBCharacteristic,error:Error?) {
        guard p===peripheral,c===rx,stage=="subscribing" else { return }
        guard error==nil,c.isNotifying else { failAll("无法接收显示器蓝牙通知");return }
        stage="ready";readyAt=clock+0.6;onConnection?(true);beginProtocol()
    }
    func peripheral(_ p:CBPeripheral,didUpdateValueFor c:CBCharacteristic,error:Error?) {
        guard p===peripheral,active != nil else { return }
        guard error==nil,let data=c.value else { failAll("读取蓝牙数据失败");return }
        if c===identity {
            guard stage=="identity",let expectedMAC,data==expectedMAC else { failAll("蓝牙设备身份不匹配，未发送控制命令");return }
            verified=true;UserDefaults.standard.set(p.identifier.uuidString,forKey:peripheralKey)
            log.record("ble_identity_verified");stage="subscribing";deadline=clock+5
            if let rx { p.setNotifyValue(true,for:rx) };return
        }
        guard c===rx,stage=="ready",machineStarted else { return }
        var frames=[GMFrame](repeating:GMFrame(),count:20)
        let count=data.withUnsafeBytes { raw -> Int32 in
            gm_decode(&decoder,raw.bindMemory(to:UInt8.self).baseAddress,data.count,&frames,frames.count)
        }
        log.record("ble_notification",["hex":data.map { String(format:"%02x",$0) }.joined(),"acceptedFrames":count])
        guard count>0 else { return }
        for i in 0..<Int(count) {
            var frame=frames[i]
            withUnsafeBytes(of:&frame.bytes) { raw in gm_frame_reply(&machine,raw.bindMemory(to:UInt8.self).baseAddress,ms) }
        }
        if gm_finished(&machine) != 0 { endProtocol() }
    }
}
