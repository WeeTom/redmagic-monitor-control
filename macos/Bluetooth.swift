import Foundation
import CoreBluetooth

// Both read-only discovery and the control connection identify the same GATT profile.
enum GM001JGATT {
    static let model = "REDMAGIC GM001J"
    static let control = CBUUID(string: "0000E0FF-3C17-D293-8E48-14FE2E4DA212")
    static let identification = CBUUID(string: "0000D0FF-3C17-D293-8E48-14FE2E4DA212")
    static let transmit = CBUUID(string: "FFE1")
    static let receive = CBUUID(string: "FFE2")
    static let address = CBUUID(string: "FFD2")
}

final class BluetoothController:NSObject,CBCentralManagerDelegate,CBPeripheralDelegate {
    struct Job {
        let feature:Feature
        let desired:Int?
        let reapply:Bool
        let completion:(Result<Int,Error>)->Void
    }
    let service=GM001JGATT.control
    let identityService=GM001JGATT.identification
    private let expectedMAC: Data?
    private let addressSuffix: String
    private var peripheralKey: String { "verifiedPeripheral." + addressSuffix }
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
    private lazy var transactionLock = expectedMAC.map { BluetoothTransactionLock(address: $0) }
    private var lockWaitDeadline: TimeInterval?
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
    init(log:EventLog,address:Data? = MonitorIdentity.address) {
        self.log=log
        expectedMAC=address
        addressSuffix=address?.map { String(format:"%02X",$0) }.joined() ?? ""
        super.init()
        central=CBCentralManager(delegate:self,queue:.main,options:[CBCentralManagerOptionShowPowerAlertKey:false])
        timer=Timer.scheduledTimer(withTimeInterval:0.1,repeats:true) { [weak self] _ in self?.tick() }
    }
    func submit(_ feature:Feature,value:Int?=nil,reapply:Bool=false,completion:@escaping(Result<Int,Error>)->Void) {
        guard expectedMAC != nil else {
            completion(.failure(DisplayError(tr("请先识别显示器后再试。")))); return
        }
        if let value,gm_value_valid(feature.rawValue,Int32(value),1)==0 {
            completion(.failure(DisplayError(tr("该设置值不受支持"))));return
        }
        if value != nil {
            let replaced=pending.filter { $0.feature==feature && $0.desired != nil }
            pending.removeAll { $0.feature==feature && $0.desired != nil }
            for old in replaced { old.completion(.failure(DDCOperationError.superseded)) }
        }
        guard pending.count<24 else { completion(.failure(DisplayError(tr("操作较多，请稍候再试"))));return }
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
        if CBManager.authorization == .denied || CBManager.authorization == .restricted {
            failAll(tr("请在系统设置 → 隐私与安全性 → 蓝牙中允许本应用"));return
        }
        guard central.state == .poweredOn else {
            stage="permission";deadline=clock+45
            if central.state == .poweredOff { failAll(tr("Mac 蓝牙已关闭，请开启后刷新")) }
            else if central.state == .unsupported { failAll(tr("当前 Mac 无法使用低功耗蓝牙")) }
            else if central.state == .unauthorized && CBManager.authorization != .notDetermined { failAll(tr("请在系统设置 → 隐私与安全性 → 蓝牙中允许本应用")) }
            else { onState?(tr("等待蓝牙授权…")) }
            return
        }
        verified=false;tx=nil;rx=nil;identity=nil;gm_decoder_reset(&decoder)
        // An already connected monitor may have stopped advertising. CoreBluetooth
        // can vend it to another local client, then FFD2 must still match the address.
        let savedText=UserDefaults.standard.string(forKey:peripheralKey)
            ?? UserDefaults.standard.persistentDomain(forName:"com.local.redmagic-display")?[peripheralKey] as? String
        let saved=savedText.flatMap(UUID.init(uuidString:))
        let connected=central.retrieveConnectedPeripherals(withServices:[service]).first {
            $0.identifier == saved || matchesName($0.name)
        }
        if let connected { connect(connected) }
        else if let saved, let cached=central.retrievePeripherals(withIdentifiers:[saved]).first { connect(cached) }
        else { scan() }
    }
    private func scan() {
        stage="scanning";deadline=clock+12;onState?(tr("正在寻找显示器…"))
        central.scanForPeripherals(withServices:[service],options:nil)
    }
    private func connect(_ p:CBPeripheral) {
        central.stopScan();peripheral=p;p.delegate=self
        stage="connecting";deadline=clock+15;onState?(tr("正在连接显示器…"))
        central.connect(p,options:nil)
    }
    private func beginProtocol() {
        guard let job=active,verified,stage=="ready",clock>=readyAt,!machineStarted else { return }
        guard let transactionLock else { failAll(tr("蓝牙设备地址未配置")); return }
        if let lockWaitDeadline, clock >= lockWaitDeadline {
            failAll(tr("显示器蓝牙正由其他操作使用，请稍后重试"))
            return
        }
        do {
            guard try transactionLock.tryAcquire() else {
                if lockWaitDeadline == nil {
                    lockWaitDeadline = clock + 30
                    onState?(tr("正在等候其他蓝牙操作完成…"))
                }
                return
            }
        } catch {
            failAll(tr("无法取得显示器蓝牙操作锁，请检查当前用户的应用支持目录"))
            return
        }
        lockWaitDeadline = nil
        gm_decoder_reset(&decoder)
        _=gm_init_feature(&machine,job.feature.rawValue,Int32(job.desired ?? -1),job.reapply ? 1:0,ms)
        machineStarted=true
        onState?(job.desired==nil ? tr("正在读取%@…", job.feature.title) : tr("正在设置%@…", job.feature.title))
    }
    private func releaseTransaction() {
        machineStarted = false
        lockWaitDeadline = nil
        gm_decoder_reset(&decoder)
        transactionLock?.release()
    }
    private func tick() {
        if stage=="ready",idlePolicy.shouldDisconnect(at:clock,isBusy:isBusy) {
            stage="idle";verified=false;expectedDisconnect=true
            onConnection?(false);onState?(tr("空闲 5 分钟，蓝牙已断开"))
            if let p=peripheral { central.cancelPeripheralConnection(p) }
        }
        guard active != nil else { return }
        if stage != "ready" {
            let connectionExpired = deadline > 0 && clock >= deadline
            let transactionExpired = machineStarted && ms >= machine.expires
            if connectionExpired || transactionExpired {
                failAll(tr("连接超时。请检查显示器蓝牙，或暂时断开头玩 App 后刷新"))
            }
            return
        }
        guard clock>=readyAt else { return }
        if !machineStarted { beginProtocol() }
        guard machineStarted,transactionLock?.isHeld == true else { return }
        guard let p=peripheral,let tx,verified else { failAll(tr("蓝牙连接尚未就绪"));return }
        if p.canSendWriteWithoutResponse || ms>=machine.expires {
            var bytes=[UInt8](repeating:0,count:3)
            if gm_poll(&machine,ms,&bytes)==1 {
                if [UInt8(0xec),0xed,0xee].contains(bytes[0]) { settingWriteCount+=1 } else { queryWriteCount+=1 }
                gm_decoder_reset(&decoder)
                log.record("ble_write",["bytes":bytes.map { String(format:"%02x",$0) }.joined(),"feature":active!.feature.titleKey])
                p.writeValue(Data(bytes),for:tx,type:.withoutResponse)
            }
        }
        if gm_finished(&machine) != 0 { endProtocol() }
    }
    private func endProtocol() {
        guard let job=active else { return }
        let result=machine.result
        log.record("ble_result",["feature":job.feature.titleKey,"result":String(cString:gm_result_name(&machine)),"before":machine.before,"after":machine.after,"setWrites":machine.set_writes,"queryWrites":machine.query_writes,"osdVisuallyVerified":false,"usbIndependentlyVerified":false])
        active=nil;releaseTransaction()
        idlePolicy.activity(at:clock);readyAt=clock+0.35
        if result>0 { job.completion(.success(Int(machine.after))) }
        else { job.completion(.failure(DisplayError(job.feature == .volume ? tr("当前固件未响应音量接口") : tr("%@未能通过回读确认，请刷新检查", job.feature.title)))) }
        startNext()
    }
    private func failAll(_ text:String) {
        log.record("ble_error",["message":text,"stage":stage])
        let jobs=([active].compactMap { $0 })+pending;active=nil;pending.removeAll();releaseTransaction()
        stage="idle";verified=false;central.stopScan()
        onConnection?(false)
        if let p=peripheral,p.state != .disconnected { expectedDisconnect=true;central.cancelPeripheralConnection(p) }
        onState?(text)
        for job in jobs { job.completion(.failure(DisplayError(text))) }
    }
    func stop() {
        failAll(tr("蓝牙已断开，可刷新重新连接"))
    }
    func centralManagerDidUpdateState(_ central:CBCentralManager) {
        log.record("ble_state",["state":central.state.rawValue,"authorization":CBManager.authorization.rawValue])
        if central.state == .poweredOn,active != nil { beginConnection() }
        else if central.state == .poweredOff,isBusy { failAll(tr("Mac 蓝牙已关闭")) }
        else if central.state == .unauthorized,CBManager.authorization != .notDetermined,isBusy { failAll(tr("请在系统设置 → 隐私与安全性 → 蓝牙中允许本应用")) }
    }
    func centralManager(_ central:CBCentralManager,didDiscover p:CBPeripheral,advertisementData:[String:Any],rssi:NSNumber) {
        guard stage=="scanning" else { return }
        let name=advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? p.name
        if matchesName(name) { connect(p) }
    }
    private func matchesName(_ name:String?) -> Bool {
        !addressSuffix.isEmpty && name?.uppercased() == GM001JGATT.model + addressSuffix
    }
    func centralManager(_ central:CBCentralManager,didConnect p:CBPeripheral) {
        guard p===peripheral,active != nil else { central.cancelPeripheralConnection(p);return }
        connectionCount+=1;log.record("ble_connected",["connectionCount":connectionCount])
        stage="discovering";deadline=clock+10;p.discoverServices([service,identityService])
    }
    func centralManager(_ central:CBCentralManager,didFailToConnect p:CBPeripheral,error:Error?) {
        guard p===peripheral,active != nil else { return }
        if connectionAttempt==0 { connectionAttempt=1;scan() } else { failAll(tr("无法连接显示器蓝牙")) }
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
        // Reconnect the same job under its existing lock. The state machine
        // resumes verification if a setting was already sent.
        if machineStarted,transactionLock?.isHeld == true,gm_reconnect(&machine,ms)==1 {
            log.record("ble_reconnect_verification_only",["setWrites":machine.set_writes]);stage="idle";beginConnection()
        } else { failAll(tr("显示器蓝牙已断开，请刷新；已发送的设置不会自动重复发送")) }
    }
    func peripheral(_ p:CBPeripheral,didDiscoverServices error:Error?) {
        guard p===peripheral,stage=="discovering" else { return }
        guard error==nil,let services=p.services,services.contains(where:{$0.uuid==service}),services.contains(where:{$0.uuid==identityService}) else { failAll(tr("显示器缺少所需的蓝牙服务"));return }
        let required=services.filter { $0.uuid==service || $0.uuid==identityService }
        discovery=Set(required.map { $0.uuid.uuidString })
        for s in required { p.discoverCharacteristics(s.uuid==service ? [GM001JGATT.transmit,GM001JGATT.receive] : [GM001JGATT.address],for:s) }
    }
    func peripheral(_ p:CBPeripheral,didDiscoverCharacteristicsFor s:CBService,error:Error?) {
        guard p===peripheral,stage=="discovering" else { return }
        guard error==nil else { failAll(tr("读取蓝牙特征失败"));return }
        for c in s.characteristics ?? [] {
            if s.uuid==service,c.uuid==GM001JGATT.transmit { tx=c }
            if s.uuid==service,c.uuid==GM001JGATT.receive { rx=c }
            if s.uuid==identityService,c.uuid==GM001JGATT.address { identity=c }
        }
        discovery.remove(s.uuid.uuidString)
        if discovery.isEmpty {
            guard let tx,tx.properties.contains(.writeWithoutResponse),let rx,rx.properties.contains(.notify),let identity,identity.properties.contains(.read) else { failAll(tr("显示器蓝牙接口与已验证协议不一致"));return }
            stage="identity";deadline=clock+5;p.readValue(for:identity)
        }
    }
    func peripheral(_ p:CBPeripheral,didUpdateNotificationStateFor c:CBCharacteristic,error:Error?) {
        guard p===peripheral,c===rx,stage=="subscribing" else { return }
        guard error==nil,c.isNotifying else { failAll(tr("无法接收显示器蓝牙通知"));return }
        stage="ready";readyAt=clock+0.6;onConnection?(true);beginProtocol()
    }
    func peripheral(_ p:CBPeripheral,didUpdateValueFor c:CBCharacteristic,error:Error?) {
        guard p===peripheral,active != nil else { return }
        if c===identity {
            guard stage=="identity" else { return }
            guard error==nil,let data=c.value else { failAll(tr("读取蓝牙数据失败"));return }
            guard let expectedMAC,data==expectedMAC else { failAll(tr("蓝牙设备身份不匹配，未发送控制命令"));return }
            verified=true;UserDefaults.standard.set(p.identifier.uuidString,forKey:peripheralKey)
            log.record("ble_identity_verified");stage="subscribing";deadline=clock+5
            if let rx { p.setNotifyValue(true,for:rx) };return
        }
        guard c===rx,stage=="ready",machineStarted,transactionLock?.isHeld == true else { return }
        guard error==nil,let data=c.value else { failAll(tr("读取蓝牙数据失败"));return }
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
