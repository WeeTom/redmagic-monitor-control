import Foundation
import Combine
import AppKit
import ServiceManagement
import CoreBluetooth

protocol DisplayBluetooth: AnyObject {
    var onState: ((String) -> Void)? { get set }
    var onConnection: ((Bool) -> Void)? { get set }
    var connectionCount: Int { get }
    var settingWriteCount: Int { get }
    var queryWriteCount: Int { get }
    func submit(_ feature: Feature, value: Int?, reapply: Bool,
                completion: @escaping (Result<Int, Error>) -> Void)
    func stop()
}

extension BluetoothController: DisplayBluetooth {}

private struct DeviceCache:Codable {
    var serial=MonitorIdentity.cacheKey
    var ddc=[String:Int](),ble=[String:Int](),dates=[String:Date]()
}
private extension ControlChannel {
    var preferenceName: String { self == .bluetooth ? "Bluetooth" : "DDC" }
}

private struct PreviousStatus: Decodable {
    let channel: String
}

final class DisplayStore:ObservableObject {
    @Published var channel=ControlChannel.ddc
    @Published var values=[Feature:Int]()
    @Published var ddcValues=[String:Int]()
    @Published var ddcDrafts=[String:Int]()
    @Published var bleDrafts=[Feature:Int]()
    @Published var ddcWriting=Set<String>()
    @Published var bleWriting=Set<Feature>()
    @Published var stale=Set<String>()
    @Published var ddcStatus="尚未检测 DDC"
    @Published var bluetoothStatus="蓝牙尚未连接"
    @Published var bluetoothConnected=false
    var status:String { channel == .ddc ? ddcStatus : bluetoothStatus }
    @Published var message=""
    @Published var pendingBLE=0
    @Published var ddcBusy=false
    let volumeUnavailable=true // Stock BLE has no volume command. DDC uses C8.
    @Published private(set) var isResettingDefaults = false
    @Published var loginEnabled=false
    @Published var lastRefresh:Date?
    let log=EventLog()
    let demo:Bool
    private let cacheURL:URL?
    private let channelDefaults: UserDefaults?
    private static let channelPreferenceKey = "lastControlChannel"
    var statusURL: URL {
        log.directory.appendingPathComponent(channelDefaults == nil ? "latest-probe-status.json" : "latest-status.json")
    }
    private var dates=[String:Date]()
    private let persistence=DispatchQueue(label:"com.local.redmagic-display.cache",qos:.utility)
    private var statusSave:DispatchWorkItem?
    private var bluetoothCreated=false,ddcCreated=false,buildingBatch=false,refreshRequested=false
    private var ddcReading=Set<String>(),bleReading=Set<Feature>()
    private var ddcGeneration=[String:Int](),bleGeneration=[Feature:Int]()
    private static let ddcFeatures = ["luminance", "volume", "input", "contrast"]
    private static let bluetoothFeatures: [Feature] = [.input, .mode, .hdr, .lightPower, .lightLevel, .lightEffect, .lightColor]
    private var confirmedDDCThisSession = Set<String>()
    private var confirmedBLEThisRun = Set<Feature>()
    private static let inputCheckInterval: TimeInterval = 5
    private let now: () -> Date
    private let canSyncMenu: () -> Bool
    private var lastInputRead = [ControlChannel: Date]()
    private var inputIntent = 0
    private var injectedDDC:DDCController?
    private let injectedBluetooth: DisplayBluetooth?
    private var reportStatus=true
    lazy var bluetooth:DisplayBluetooth = {
        bluetoothCreated=true
        let b = injectedBluetooth ?? BluetoothController(log:log)
        b.onState={ [weak self] text in self?.bluetoothStatus=text }
        b.onConnection={ [weak self] connected in
            guard let self else { return }
            self.bluetoothConnected = connected
            if !connected {
                self.bluetoothStatus = "蓝牙已断开"
                self.confirmedBLEThisRun.remove(.input)
                if self.values[.input] != nil { self.stale.insert("b:\(Feature.input.rawValue)") }
            }
        }
        return b
    }()
    lazy var ddc:DDCController = {
        ddcCreated=true
        let d=injectedDDC ?? DDCController(log:log)
        d.onActivity={ [weak self] active in self?.ddcBusy=active;self?.changed();self?.finishRefresh() }
        return d
    }()
    var onChange:(()->Void)?
    var onRefreshComplete:(()->Void)?
    var busy:Bool { pendingBLE>0 || ddcBusy || !ddcReading.isEmpty || !ddcWriting.isEmpty }
    var inputBusy:Bool { ddcWriting.contains("input") || bleWriting.contains(.input) }
    var inputMismatch: (active: String, menu: String)? {
        let menuKey = "b:\(Feature.input.rawValue)"
        guard !inputBusy, bluetoothConnected, confirmedDDCThisSession.contains("input"), confirmedBLEThisRun.contains(.input),
              !stale.contains("d:input"), !stale.contains(menuKey), ddcDrafts["input"] == nil, bleDrafts[.input] == nil,
              let activeDate = dates["d:input"], let menuDate = dates[menuKey],
              now().timeIntervalSince(min(activeDate, menuDate)) < Self.inputCheckInterval,
              let active = MonitorInput.ports.first(where: { $0.ddc == ddcValues["input"] }),
              let menu = values[.input], active.bluetooth != menu else { return nil }
        return (active.name, Feature.input.label(menu))
    }
    init(demo:Bool=false,ddc:DDCController?=nil,bluetooth:DisplayBluetooth?=nil,cacheURL:URL?=nil,loadCache:Bool=true,
         channelDefaults: UserDefaults? = nil, previousStatusURL: URL? = nil,
         now: @escaping () -> Date = Date.init, canSyncMenu: (() -> Bool)? = nil) {
        self.now = now
        let usesSystemTransports = ddc == nil && bluetooth == nil
        self.canSyncMenu = canSyncMenu ?? {
            usesSystemTransports && MonitorIdentity.address != nil && CBManager.authorization == .allowedAlways
        }
        self.channelDefaults = demo ? nil : channelDefaults
        self.demo=demo;self.injectedDDC=ddc;self.injectedBluetooth=bluetooth;self.reportStatus=ddc==nil && bluetooth==nil
        self.cacheURL=demo ? nil : (cacheURL ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/RedMagicDisplay/cache-\(MonitorIdentity.cacheKey).json"))
        if let defaults = self.channelDefaults {
            channel = Self.initialChannel(defaults: defaults,
                                          previousStatus: previousStatusURL ?? log.directory.appendingPathComponent("latest-status.json"))
        }
        loginEnabled=SMAppService.mainApp.status == .enabled
        if demo {
            values=[.input:1,.mode:7,.hdr:2,.lightPower:1,.lightColor:7,.lightLevel:1,.lightEffect:2]
            ddcValues=["input":7,"luminance":81,"contrast":50,"volume":0]
            ddcStatus="DDC · Type-C";bluetoothStatus="蓝牙已连接 · Type-C";bluetoothConnected=true;lastRefresh=Date()
        } else if loadCache,let url=self.cacheURL,let data=try? Data(contentsOf:url),let c=try? JSONDecoder().decode(DeviceCache.self,from:data),c.serial==MonitorIdentity.cacheKey {
            ddcValues=c.ddc.filter { Self.ddcFeatures.contains($0.key) && (0...100).contains($0.value) }
            for (k,v) in c.ble { if let id=Int32(k),let f=Feature(rawValue:id),f != .volume,gm_value_valid(f.rawValue,Int32(v),0) != 0 { values[f]=v } }
            dates=c.dates;stale=Set(ddcValues.keys.map { "d:"+$0 }+values.keys.map { "b:\($0.rawValue)" })
            if !ddcValues.isEmpty { ddcStatus="DDC · 上次确认的状态" }
        }
    }
    private static func initialChannel(defaults: UserDefaults, previousStatus: URL) -> ControlChannel {
        if let saved = defaults.object(forKey: channelPreferenceKey) {
            return saved as? String == ControlChannel.bluetooth.preferenceName ? .bluetooth : .ddc
        }
        // Versions through 0.4.1 included the selected page in their status snapshot.
        let previous = (try? Data(contentsOf: previousStatus)).flatMap {
            try? JSONDecoder().decode(PreviousStatus.self, from: $0)
        }
        let selected: ControlChannel = previous?.channel == ControlChannel.bluetooth.preferenceName ? .bluetooth : .ddc
        defaults.set(selected.preferenceName, forKey: channelPreferenceKey)
        return selected
    }
    func displayedDDC(_ key:String)->Int? { ddcDrafts[key] ?? ddcValues[key] }
    func displayedBLE(_ feature:Feature)->Int? { bleDrafts[feature] ?? values[feature] }
    func noteDDC(_ key:String)->String {
        if ddcWriting.contains(key) { return "正在确认" }
        if ddcDrafts[key] != nil { return "待确认" }
        return stale.contains("d:"+key) ? "上次确认":""
    }
    func noteBLE(_ f:Feature)->String {
        if bleWriting.contains(f) { return "正在确认" }
        if bleDrafts[f] != nil { return "待确认" }
        return stale.contains("b:\(f.rawValue)") ? "上次确认":""
    }
    private func persist() {
        guard !demo,let cacheURL else { return }
        let c=DeviceCache(ddc:ddcValues,ble:Dictionary(uniqueKeysWithValues:values.map { (String($0.key.rawValue),$0.value) }),dates:dates)
        guard let data=try? JSONEncoder().encode(c) else { return }
        persistence.async {
            try? FileManager.default.createDirectory(at:cacheURL.deletingLastPathComponent(),withIntermediateDirectories:true)
            try? data.write(to:cacheURL,options:.atomic)
        }
    }
    private func changed() {
        onChange?()
        guard !demo,reportStatus else { return }
        statusSave?.cancel()
        let state:[String:Any] = ["channel":channel.preferenceName,"status":status,"message":message,"pendingBLE":pendingBLE,"ddcBusy":ddcBusy,"ddcValues":ddcValues,"ddcDrafts":ddcDrafts,"stale":Array(stale),"bluetoothValues":Dictionary(uniqueKeysWithValues:values.map { ($0.key.title,$0.value) }),"bluetoothConnected":bluetoothConnected,"bluetoothIdleDisconnectSeconds":300,"volumeMaximum":100,"volumeTransport":"DDC factory C8","channelSelectionPolicy":"read missing values; reconnect Bluetooth on entry when disconnected","bluetoothControllerCreated":bluetoothCreated,"automaticRefreshWritesSettings":false]
        let url=statusURL
        let job=DispatchWorkItem { if let data=try? JSONSerialization.data(withJSONObject:state,options:[.prettyPrinted,.sortedKeys]) { try? data.write(to:url,options:.atomic) } }
        statusSave=job;persistence.asyncAfter(deadline:.now()+0.1,execute:job)
    }
    private func finishRefresh() {
        if refreshRequested && !buildingBatch && !busy && bleReading.isEmpty {
            refreshRequested=false;onRefreshComplete?()
        }
    }
    func start() { loadSelectedChannelIfNeeded() }
    func panelOpened() { loadSelectedChannelIfNeeded() }

    func selectChannel(_ selected: ControlChannel) {
        guard selected != channel else { return }
        channel = selected
        channelDefaults?.set(selected.preferenceName, forKey: Self.channelPreferenceKey)
        message = ""
        changed()
        loadSelectedChannelIfNeeded()
    }

    private func loadSelectedChannelIfNeeded() {
        guard !demo else { return }
        // An external host can change the input while this popover is closed.
        // Revisit only that setting on a warm connection and coalesce rapid opens.
        let checkInput = !inputBusy && now().timeIntervalSince(lastInputRead[channel] ?? .distantPast) >= Self.inputCheckInterval
        if channel == .ddc {
            let missing = Self.ddcFeatures.filter {
                if $0 == "input" && inputBusy { return false }
                return !confirmedDDCThisSession.contains($0) || ($0 == "input" && checkInput)
            }
            if !missing.isEmpty { refreshDDC(missing) }
        } else if bluetoothConnected {
            if checkInput && confirmedBLEThisRun.contains(.input) { request(.input) }
            readMissingBluetoothFeatures()
        } else {
            // This single read starts the verified connection, including after idle
            // disconnect. A second page visit reuses the same pending input query.
            request(.input, completion: { [weak self] in self?.readMissingBluetoothFeatures() })
        }
    }

    private func readMissingBluetoothFeatures() {
        var features = Self.bluetoothFeatures
        if values[.lightEffect] == 7 { features += [.frontColor, .rearColor] }
        for feature in features where !confirmedBLEThisRun.contains(feature) {
            readBluetooth(feature, onlyMissing: true)
        }
    }

    private func readBluetooth(_ feature: Feature, onlyMissing: Bool) {
        request(feature, completion: { [weak self] in
            guard let self, feature == .lightEffect, self.values[feature] == 7 else { return }
            for color: Feature in [.frontColor, .rearColor] where !onlyMissing || !self.confirmedBLEThisRun.contains(color) {
                self.request(color)
            }
        })
    }

    func refresh() {
        guard !demo else { return }
        message="";refreshRequested=true;buildingBatch=true
        if channel == .ddc { refreshDDC(Self.ddcFeatures) }
        else { Self.bluetoothFeatures.forEach { readBluetooth($0, onlyMissing: false) } }
        buildingBatch=false;finishRefresh()
    }
    private func refreshDDC(_ features:[String]) {
        guard !demo else { return }
        guard injectedDDC != nil || !MonitorIdentity.serial.isEmpty else {
            ddcStatus="请配置显示器 MonitorSerial 并重启应用"; changed(); return
        }
        for f in features where !ddcReading.contains(f) && !ddcWriting.contains(f) {
            if f == "input" {
                guard !inputBusy else { continue }
                lastInputRead[.ddc] = now()
                if ddcValues[f] != nil { stale.insert("d:input") }
            }
            ddcReading.insert(f)
            let generation=ddcGeneration[f,default:0]
            ddc.read(f) { [weak self] result in
                guard let self else { return };self.ddcReading.remove(f)
                if generation==self.ddcGeneration[f,default:0] && !self.ddcWriting.contains(f) {
                    if case .success(let v)=result {
                        self.confirmedDDCThisSession.insert(f)
                        self.ddcValues[f]=v;self.ddcDrafts.removeValue(forKey:f);self.stale.remove("d:"+f);self.dates["d:"+f]=self.now();self.persist()
                    } else { self.stale.insert("d:"+f) }
                }
                if self.ddcReading.isEmpty { self.lastRefresh=Date();self.ddcStatus=self.ddcValues.isEmpty ? "DDC 暂不可用 · 可刷新重试":"DDC · 已保留最近状态" }
                self.changed();self.finishRefresh()
            }
        }
        changed()
    }
    private func request(_ f:Feature,value:Int?=nil,reapply:Bool=false,onFailure:((Error)->Void)?=nil,completion:(()->Void)?=nil) {
        guard f != .volume else { return }
        if value==nil && (bleReading.contains(f) || bleWriting.contains(f)) { return }
        if f == .input && value == nil && inputBusy { return }
        if demo { if let value { values[f]=value };completion?();changed();return }
        guard injectedBluetooth != nil || MonitorIdentity.address != nil else {
            bluetoothStatus="请配置显示器 BluetoothAddress 并重启应用"; changed(); return
        }
        let generation:Int
        if let value {
            bleGeneration[f,default:0]+=1;generation=bleGeneration[f]!
            bleDrafts[f]=value;bleWriting.insert(f)
        } else {
            generation=bleGeneration[f,default:0];bleReading.insert(f)
            if f == .input {
                lastInputRead[.bluetooth] = now()
                if values[f] != nil { stale.insert("b:\(f.rawValue)") }
            }
        }
        pendingBLE+=1;changed()
        bluetooth.submit(f,value:value,reapply:reapply) { [weak self] result in
            guard let self else { return };self.pendingBLE-=1
            if value==nil { self.bleReading.remove(f) }
            if generation==self.bleGeneration[f,default:0] {
                if value != nil { self.bleWriting.remove(f) }
                switch result {
                case .success(let actual):
                    self.confirmedBLEThisRun.insert(f)
                    self.values[f]=actual;self.bleDrafts.removeValue(forKey:f);self.stale.remove("b:\(f.rawValue)");self.dates["b:\(f.rawValue)"]=self.now();self.persist()
                    if f == .input { self.lastInputRead[.bluetooth] = self.now() }
                    if value != nil { self.message="\(f.title)已回读确认" }
                    completion?()
                case .failure(let error):
                    self.stale.insert("b:\(f.rawValue)");self.message=error.localizedDescription;onFailure?(error)
                }
            }
            if self.pendingBLE == 0 {
                self.lastRefresh = Date()
                if self.bluetoothConnected {
                    self.bluetoothStatus = "蓝牙已连接"
                }
            }
            self.changed();self.finishRefresh()
        }
    }
    func set(_ f:Feature,_ value:Int,reapply:Bool=false) {
        guard channel == .bluetooth,f != .volume,gm_value_valid(f.rawValue,Int32(value),1) != 0 else { return }
        if f == .input && inputBusy { return }
        if f == .lightPower && value==2 {
            // EE0102 is ignored by stock firmware. Reapply the actual effect.
            let enable:()->Void = { [weak self] in
                guard let self,let effect=self.values[.lightEffect] else { return }
                self.request(.lightEffect,value:effect,reapply:true,completion:{ [weak self] in self?.request(.lightPower) })
            }
            if values[.lightEffect]==nil { request(.lightEffect,completion:enable) } else { enable() };return
        }
        if f == .input {
            inputIntent += 1
            markDDCStale(Self.ddcFeatures)
        }
        request(f,value:value,reapply:reapply || f == .input,completion:{ [weak self] in
            guard let self else { return }
            if f == .input {
                self.markDDCStale(Self.ddcFeatures)
                if self.channel == .bluetooth { self.readMissingBluetoothFeatures() }
            }
            if f == .lightEffect && self.values[f]==7 { self.request(.frontColor);self.request(.rearColor) }
        })
    }
    func setDDC(_ feature: String, _ value: Int) {
        guard channel == .ddc, DDCController.canWrite(feature, value),
              displayedDDC(feature) != nil || feature == "input",
              !(feature == "input" && inputBusy) else { return }
        if feature == "input" { inputIntent += 1 }
        let intent = inputIntent
        writeDDC(feature, value: value) { [weak self] result in
            guard let self else { return }
            if feature == "input" {
                guard intent == self.inputIntent else { return }
                self.finishDDCInput(value, result: result)
                return
            }
            switch result {
            case .success:
                self.message = "设置已回读确认"
            case .failure(DDCOperationError.superseded): break
            case .failure(let error): self.message = error.localizedDescription
            }
        }
    }

    private func finishDDCInput(_ value: Int, result: Result<Int, Error>) {
        guard let port = MonitorInput.ports.first(where: { $0.ddc == value }) else { return }
        let ddcReport: String
        switch result {
        case .success: ddcReport = "DDC 已确认 \(port.name)"
        case .failure(DDCOperationError.unconfirmed): ddcReport = "DDC 已发送，活动输入尚未确认"
        case .failure(DDCOperationError.superseded): return
        case .failure(let error): message = error.localizedDescription; return
        }
        guard !demo, bluetoothConnected || canSyncMenu() else {
            message = "\(ddcReport)。可在蓝牙页选择 \(port.name) 同步显示器菜单"
            return
        }
        message = "\(ddcReport)，正在同步显示器菜单"
        request(.input, value: port.bluetooth, reapply: true, onFailure: { [weak self] _ in
            self?.message = "\(ddcReport)。蓝牙未能确认菜单设置，请在蓝牙页重试"
        }) { [weak self] in
            guard let self else { return }
            self.message = "\(ddcReport)，蓝牙已确认菜单为 \(port.name)"
            if self.channel == .bluetooth { self.readMissingBluetoothFeatures() }
        }
    }

    func resetDefaults() {
        guard !isResettingDefaults else { return }
        isResettingDefaults = true
        message = "正在恢复亮度和对比度…"
        let defaults = [("luminance", "亮度"), ("contrast", "对比度")]
        var remaining = defaults.count
        var confirmed = [String]()
        var unconfirmed = [String]()
        for (feature, title) in defaults {
            writeDDC(feature, value: 50) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success: confirmed.append(title)
                case .failure: unconfirmed.append(title)
                }
                remaining -= 1
                guard remaining == 0 else { return }
                self.isResettingDefaults = false
                if unconfirmed.isEmpty {
                    self.message = "亮度和对比度均已恢复到 50"
                } else {
                    let applied = confirmed.isEmpty ? "" : confirmed.joined(separator: "、") + "已恢复到 50。"
                    self.message = applied + unconfirmed.joined(separator: "、") + "未确认恢复，请刷新检查"
                }
            }
        }
    }

    private func markDDCStale(_ features: [String]) {
        for feature in features where !ddcWriting.contains(feature) {
            confirmedDDCThisSession.remove(feature)
            if ddcValues[feature] != nil { stale.insert("d:" + feature) }
            ddcGeneration[feature, default: 0] += 1
        }
    }

    private func writeDDC(_ feature: String, value: Int, completion: @escaping DDCController.Completion) {
        if demo { ddcValues[feature] = value; completion(.success(value)); changed(); return }
        guard injectedDDC != nil || !MonitorIdentity.serial.isEmpty else {
            completion(.failure(DisplayError("请配置显示器 MonitorSerial 并重启应用"))); return
        }
        ddcGeneration[feature, default: 0] += 1
        let generation = ddcGeneration[feature]
        ddcDrafts[feature] = value
        ddcWriting.insert(feature)
        changed()
        ddc.write(feature, value: value) { [weak self] result in
            guard let self else { return }
            guard generation == self.ddcGeneration[feature] else {
                completion(.failure(DDCOperationError.superseded)); self.changed(); return
            }
            self.ddcWriting.remove(feature)
            if feature == "input" {
                // Even an unconfirmed input write can have changed the source.
                // DDC and BLE report different input encodings; each must reread.
                self.confirmedBLEThisRun.remove(.input)
                self.bleGeneration[.input, default: 0] += 1
                if self.values[.input] != nil { self.stale.insert("b:\(Feature.input.rawValue)") }
                self.markDDCStale(["luminance", "contrast"])
            }
            switch result {
            case .success(let actual):
                self.confirmedDDCThisSession.insert(feature)
                self.ddcValues[feature] = actual
                self.ddcDrafts.removeValue(forKey: feature)
                self.stale.remove("d:" + feature)
                self.dates["d:" + feature] = self.now()
                if feature == "input" { self.lastInputRead[.ddc] = self.now() }
                self.persist()
            case .failure: self.stale.insert("d:" + feature)
            }
            completion(result)
            self.changed()
            self.finishRefresh()
        }
    }
    func disconnectBluetooth() { inputIntent += 1; guard bluetoothCreated else { return };bluetooth.stop();changed() }
    func toggleLogin(_ enabled:Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginEnabled=SMAppService.mainApp.status == .enabled
            if enabled && !loginEnabled { message="请在系统设置的登录项中允许本应用" }
        } catch { message="登录项设置失败：\(error.localizedDescription)" }
    }
    func stop() {
        inputIntent += 1
        confirmedDDCThisSession.removeAll()
        if !demo { if bluetoothCreated { bluetooth.stop() };if ddcCreated { ddc.invalidate() } }
    }
}
