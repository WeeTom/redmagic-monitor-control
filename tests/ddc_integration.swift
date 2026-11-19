import Foundation
import Darwin
@main struct DDCIntegration {
    static func main() {
        let folder=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/com.local.redmagic-display")
        try? FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let fd=open(folder.appendingPathComponent("app.lock").path,O_CREAT|O_RDWR,0o600)
        guard fd>=0,flock(fd,LOCK_EX|LOCK_NB)==0 else { fatalError("Quit resident app before integration test") }
        defer { close(fd) }
        let c=DDCController(log:EventLog())
        var records=[[String:Any]]()
        func run(_ f:String,_ v:Int?=nil)->Int? {
            var finished=false,value:Int?
            let start=ProcessInfo.processInfo.systemUptime
            let completion:(Result<Int,Error>)->Void = { r in
                var row:[String:Any]=["feature":f,"kind":v==nil ? "read":"write-and-verify","ms":Int((ProcessInfo.processInfo.systemUptime-start)*1000)]
                if let v { row["desired"]=v }
                switch r { case .success(let actual):value=actual;row["actual"]=actual;row["success"]=true
                case .failure(let e):row["success"]=false;row["error"]=e.localizedDescription }
                records.append(row);finished=true
            }
            if let v { c.write(f,value:v,completion:completion) } else { c.read(f,completion:completion) }
            let deadline=Date().addingTimeInterval(15)
            while !finished && Date()<deadline { _=RunLoop.current.run(mode:.default,before:Date().addingTimeInterval(0.01)) }
            precondition(finished);return value
        }
        let baseline=CommandLine.arguments.contains("--volume-only") ? nil:run("luminance")
        if baseline != nil { for _ in 0..<4 { _=run("luminance") } }
        _=run("volume")
        if let baseline,baseline>0 {
            _=run("luminance",baseline-1)
            _=run("luminance",baseline)
            if run("luminance") != baseline { _=run("luminance",baseline);_=run("luminance") }
        }
        _=run("volume",0) // Never raise headphone volume.
        let report:[String:Any]=["baseline":baseline as Any? ?? NSNull(),"records":records,"statistics":c.statistics,"volumeLeftAt":0,"test":baseline==nil ? "real native session; volume zero only":"real native session; brightness down one then restored; volume zero only"]
        let data=try! JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])
        try! data.write(to:URL(fileURLWithPath:CommandLine.arguments[1]));print(String(data:data,encoding:.utf8)!)
        c.invalidate()
    }
}
