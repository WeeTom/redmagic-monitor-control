import Foundation

struct DDCSample {
    let status:Int
    let value:Int
    let maximum:Int
    let raw:String
}
protocol DDCTransport:AnyObject {
    func read(_ feature:String,attempt:Int)->DDCSample
    func write(_ feature:String,value:Int)->Int
    func invalidate()
}
final class NativeDDCTransport:DDCTransport {
    static let codes:[String:UInt8] = ["input":0x60,"luminance":0x10,"contrast":0x12,"volume":0x62]
    private let serial: String
    private let writeLockTimeout: TimeInterval
    private var session:OpaquePointer?
    private(set) var opens=0
    init(serial: String = MonitorIdentity.serial, writeLockTimeout: TimeInterval = 0) {
        self.serial = serial
        self.writeLockTimeout = writeLockTimeout
    }
    private func connection()->OpaquePointer? {
        if session==nil { session=gm_ddc_open_for_serial(serial);if session != nil { opens+=1 } }
        return session
    }
    func read(_ feature:String,attempt:Int)->DDCSample {
        guard let code=Self.codes[feature],let s=connection() else { return DDCSample(status:3,value:0,maximum:0,raw:"") }
        var r:GMDDCReply
        // Factory brightness is raw 0..255, unlike the standard 0..100 value.
        // Never use it as a brightness fallback. Factory volume is equivalent.
        if feature=="volume" && attempt%3==2 { r=gm_ddc_read(s,code,1,100) }
        else {
            let counts:[Int32]=[2,4,2,3],waits:[Int32]=[50,50,150,100]
            r=gm_ddc_read_tuned(s,code,counts[attempt%4],50,waits[attempt%4],11)
        }
        let raw=withUnsafeBytes(of:&r.raw) { bytes in bytes.prefix(max(0,min(16,Int(r.length)))).map { String(format:"%02x",$0) }.joined() }
        if r.status==3 { invalidate() }
        return DDCSample(status:Int(r.status),value:Int(r.value),maximum:Int(r.maximum),raw:raw)
    }
    func write(_ feature:String,value:Int)->Int {
        guard let code=Self.codes[feature],DDCController.canWrite(feature,value),let s=connection() else { return -1 }
        let deadline = ProcessInfo.processInfo.systemUptime + writeLockTimeout
        var result = Int(gm_ddc_write(s, code, UInt16(value)))
        // Only -2 guarantees that no bytes were sent: another process holds the lock.
        while result == -2 && ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.05)
            result = Int(gm_ddc_write(s, code, UInt16(value)))
        }
        if result != 0 && result != -2 { invalidate() }
        return result
    }
    func invalidate() { if let session { gm_ddc_close(session) };session=nil }
    deinit { invalidate() }
}
enum DDCOperationError:LocalizedError {
    case superseded,unavailable,unconfirmed
    var errorDescription:String? {
        switch self {
        case .superseded:return "已由较新的调节取代"
        case .unavailable:return "DDC 暂未返回有效状态，保留上次确认的数值"
        case .unconfirmed:return "设置已发送，尚未回读确认；请刷新检查实际状态"
        }
    }
}

// One transaction per pump turn: absolute writes preempt background read retries.
// The persistent native session belongs to this queue, never to the UI thread.
final class DDCController {
    typealias Completion=(Result<Int,Error>)->Void
    static let inputChoices = MonitorInput.ports.map { ($0.ddc, $0.name) }
    static let supported=Set(NativeDDCTransport.codes.keys)
    static let readable=supported
    static func canWrite(_ feature:String,_ value:Int)->Bool {
        guard let code=NativeDDCTransport.codes[feature],value>=0,value<=65535 else { return false }
        return gm_ddc_can_write(code,UInt16(value)) != 0
    }
    static func valid(_ sample:DDCSample,feature:String)->Bool {
        guard sample.status==0,sample.value>=0 else { return false }
        if feature=="input" { return sample.value<=255 }
        // Stock GM001J volume uses the non-continuous marker 0xffff as max.
        // The current value is reported on the OSD scale of 0..100.
        if feature=="volume" { return sample.value<=100 && (sample.maximum==100 || sample.maximum==65535) }
        return sample.maximum>0 && sample.maximum<=100 && sample.value<=sample.maximum
    }
    static func parse(_ text:String)->Int? {
        let c=text.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !c.isEmpty,c.utf8.allSatisfy({$0>=48 && $0<=57}),let v=Int(c),(0...100).contains(v) else { return nil }
        return v
    }
    private struct Write {
        let feature:String,value:Int,sequence:Int
        let completion:Completion
    }
    private struct Query {
        let feature:String,desired:Int?,sequence:Int,budget:TimeInterval
        var due:TimeInterval,spent:TimeInterval=0,attempts=0,matches=0
        var completions:[Completion]
    }
    private let worker=DispatchQueue(label:"com.local.redmagic-display.ddc",qos:.userInitiated)
    private let transport:DDCTransport
    private let log:EventLog
    private var writes=[String:Write](),queries=[String:Query]()
    private var serial=0,scheduled=false,activity=false
    private var readCount=0,invalidCount=0,writeCount=0,coalescedCount=0
    var onActivity:((Bool)->Void)?
    init(log:EventLog,transport:DDCTransport?=nil) { self.log=log;self.transport=transport ?? NativeDDCTransport() }
    private var now:TimeInterval { ProcessInfo.processInfo.systemUptime }
    private func deliver(_ callbacks:[Completion],_ result:Result<Int,Error>) { DispatchQueue.main.async { callbacks.forEach { $0(result) } } }
    private func updateActivity() {
        let next = !writes.isEmpty || !queries.isEmpty
        if next != activity { activity=next;DispatchQueue.main.async { self.onActivity?(next) } }
    }
    private func schedule(_ delay:TimeInterval=0) {
        guard !scheduled else { return };scheduled=true
        worker.asyncAfter(deadline:.now()+delay) { self.scheduled=false;self.pump() }
    }
    func read(_ feature:String,completion:@escaping Completion) {
        guard Self.readable.contains(feature) else { completion(.failure(DDCOperationError.unavailable));return }
        worker.async {
            if var q=self.queries[feature] { q.completions.append(completion);self.queries[feature]=q }
            else { self.serial+=1;self.queries[feature]=Query(feature:feature,desired:nil,sequence:self.serial,budget:5,due:self.now,completions:[completion]) }
            self.updateActivity();self.schedule()
        }
    }
    func write(_ feature:String,value:Int,completion:@escaping Completion) {
        guard Self.canWrite(feature,value) else { completion(.failure(DisplayError("设置值超出范围")));return }
        worker.async {
            if let old=self.writes.removeValue(forKey:feature) { self.coalescedCount+=1;self.deliver([old.completion],.failure(DDCOperationError.superseded)) }
            if let old=self.queries.removeValue(forKey:feature) { self.deliver(old.completions,.failure(DDCOperationError.superseded)) }
            self.serial+=1;self.writes[feature]=Write(feature:feature,value:value,sequence:self.serial,completion:completion)
            self.updateActivity();self.schedule()
        }
    }
    private func finish(_ q:Query,_ result:Result<Int,Error>) {
        queries.removeValue(forKey:q.feature);deliver(q.completions,result)
        log.record("ddc_operation",["feature":q.feature,"desired":q.desired as Any? ?? NSNull(),"attempts":q.attempts,"matches":q.matches,"success":(try? result.get()) != nil])
    }
    private func pump() {
        if let w=writes.values.min(by:{$0.sequence<$1.sequence}) {
            writes.removeValue(forKey:w.feature)
            let result=transport.write(w.feature,value:w.value);writeCount+=1
            log.record("ddc_native_write",["feature":w.feature,"value":w.value,"result":result])
            if result==0 {
                // Reads queued after the write share its verified readback.
                let readCallbacks = queries[w.feature]?.completions ?? []
                queries[w.feature] = Query(feature:w.feature,desired:w.value,sequence:w.sequence,
                                           budget:8,due:now+0.12,completions:[w.completion] + readCallbacks)
            }
            else { deliver([w.completion],.failure(DDCOperationError.unavailable)) }
        } else if let q=queries.values.filter({$0.due<=now}).sorted(by:{ a,b in
            if (a.desired != nil) != (b.desired != nil) { return a.desired != nil }
            if a.due != b.due { return a.due<b.due };return a.sequence<b.sequence
        }).first {
            var next=q
            let began=now
            let sample=transport.read(q.feature,attempt:q.attempts);readCount+=1;next.attempts+=1;next.spent+=now-began
            let valid=Self.valid(sample,feature:q.feature)
            log.record("ddc_native_read",["feature":q.feature,"attempt":next.attempts,"valid":valid,"status":sample.status,"value":sample.value,"max":sample.maximum,"raw":sample.raw])
            if valid {
                if let target=q.desired { next.matches=sample.value==target ? next.matches+1:0 }
                if q.desired==nil || next.matches>=2 { finish(next,.success(sample.value)) }
                else { next.due=now+0.08;queries[q.feature]=next }
            } else { invalidCount+=1;next.due=now+0.04;queries[q.feature]=next }
            if queries[q.feature] != nil && (next.spent>=q.budget || next.attempts >= (q.desired==nil ? 14:26)) { finish(next,.failure(q.desired==nil ? DDCOperationError.unavailable:DDCOperationError.unconfirmed)) }
        }
        updateActivity()
        if !writes.isEmpty { schedule() }
        else if let due=queries.values.map(\.due).min() { schedule(max(0,min(0.05,due-now))) }
    }
    func invalidate() {
        worker.async {
            self.writes.values.forEach { self.deliver([$0.completion],.failure(DDCOperationError.superseded)) }
            self.queries.values.forEach { self.deliver($0.completions,.failure(DDCOperationError.superseded)) }
            self.writes.removeAll();self.queries.removeAll();self.transport.invalidate();self.updateActivity()
        }
    }
    var statistics:[String:Int] { worker.sync { ["reads":readCount,"invalidReplies":invalidCount,"writes":writeCount,"coalescedWrites":coalescedCount,"sessionOpens":(transport as? NativeDDCTransport)?.opens ?? 0] } }
}
