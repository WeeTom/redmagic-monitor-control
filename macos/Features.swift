import Foundation

enum ControlChannel:Int,CaseIterable { case ddc,bluetooth }
struct ConnectionIdlePolicy {
    let interval:TimeInterval
    private(set) var deadline=TimeInterval.infinity
    init(interval:TimeInterval=300) { self.interval=interval }
    mutating func activity(at now:TimeInterval) { deadline=now+interval }
    func shouldDisconnect(at now:TimeInterval,isBusy:Bool)->Bool { !isBusy && now>=deadline }
}

// Physical ports of the GM001J standard edition. BLE reports the selected ID.
struct MonitorInput {
    let name: String
    let bluetooth: Int
    let ddc: Int

    static let ports = [
        MonitorInput(name: "Type-C", bluetooth: 1, ddc: 7),
        MonitorInput(name: "DP", bluetooth: 2, ddc: 8),
        MonitorInput(name: "HDMI 1", bluetooth: 3, ddc: 5),
        MonitorInput(name: "HDMI 2", bluetooth: 4, ddc: 6)
    ]
}

enum Feature: Int32, CaseIterable {
    case input=0, mode, hdr, lightPower, lightColor, lightLevel, lightEffect, frontColor, rearColor, volume
    var title: String {
        switch self {
        case .input:return "输入源"; case .mode:return "画面模式"; case .hdr:return "HDR"
        case .lightPower:return "氛围灯"; case .lightColor:return "灯光颜色"
        case .lightLevel:return "灯光亮度"; case .lightEffect:return "灯光效果"
        case .frontColor:return "前灯颜色"; case .rearColor:return "背灯颜色"; case .volume:return "耳机音量"
        }
    }
    var choices: [(Int,String)] {
        switch self {
        case .input:return MonitorInput.ports.map { ($0.bluetooth, $0.name) }
        case .mode:return [(0,"标准"),(1,"电影"),(2,"FPS"),(3,"MOBA"),(4,"护眼"),(5,"sRGB"),(6,"Adobe RGB"),(7,"DCI-P3")]
        case .hdr:return [(1,"开启"),(2,"关闭")]
        case .lightPower:return [(1,"关闭"),(2,"开启")]
        case .lightLevel:return [(1,"明亮"),(2,"适中"),(3,"柔和")]
        case .lightEffect:return [(1,"常亮"),(2,"呼吸"),(3,"闪烁"),(4,"单色流动"),(5,"星光"),(6,"多彩"),(7,"多彩流动")]
        case .lightColor: return [(1,"红色"),(2,"黄色"),(3,"绿色"),(4,"青色"),(5,"蓝色"),(6,"紫色"),(7,"多彩")]
        case .frontColor, .rearColor:return [(1,"红色"),(2,"黄色"),(3,"绿色"),(4,"青色"),(5,"蓝色"),(6,"紫色")]
        case .volume:return []
        }
    }
    func label(_ value: Int) -> String { choices.first { $0.0==value }?.1 ?? (self == .input && value==0 ? "自动选择" : "未识别的当前设置") }
}

final class EventLog {
    let directory: URL
    let file: URL
    private let lock=NSLock()
    init() {
        directory=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/RedMagicDisplay",isDirectory:true)
        try? FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        file=directory.appendingPathComponent("session-\(Int(Date().timeIntervalSince1970*1000)).jsonl")
        FileManager.default.createFile(atPath:file.path,contents:nil)
    }
    func record(_ event:String,_ fields:[String:Any]=[:]) {
        lock.lock();defer { lock.unlock() }
        var row=fields;row["event"]=event;row["time"]=ISO8601DateFormatter().string(from:Date())
        guard let data=try? JSONSerialization.data(withJSONObject:row,options:.sortedKeys),
              let h=try? FileHandle(forWritingTo:file) else { return }
        defer { try? h.close() };h.seekToEndOfFile();h.write(data);h.write(Data([10]))
    }
}

struct DisplayError: LocalizedError {
    let message:String
    var errorDescription:String? { message }
    init(_ message:String) { self.message=message }
}
