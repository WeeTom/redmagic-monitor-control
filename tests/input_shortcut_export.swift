import Foundation

// Compile with macos/Features.swift and macos/InputShortcutExporter.swift.
// /usr/bin/true stands in for the monitor runner; no display commands are sent.
@main
struct InputShortcutExportChecks {
    static func refuses(_ operation: () throws -> Void) {
        do { try operation() } catch { return }
        preconditionFailure("Expected export to be refused")
    }

    static func info(_ app: URL) throws -> [String: Any] {
        let bytes = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        return try PropertyListSerialization.propertyList(from: bytes, format: nil) as! [String: Any]
    }

    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ShortcutChecks-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("Controller.app")
        let helper = source.appendingPathComponent("Contents/Helpers/InputShortcutRunner")
        let resources = source.appendingPathComponent("Contents/Resources")
        try fm.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: resources, withIntermediateDirectories: true)
        try fm.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: helper)
        for file in ["AppIcon.icns", "LICENSE.txt", "m1ddc-LICENSE.txt"] {
            try Data(file.utf8).write(to: resources.appendingPathComponent(file))
        }
        let destination = root.appendingPathComponent("快捷 $(example) & DP.app")
        var identifier: String?
        for port in MonitorInput.ports {
            try InputShortcutExporter.export(port: port, serial: " Test EDID ", to: destination,
                                             replaceExisting: identifier != nil, sourceBundle: source)
            let plist = try info(destination)
            precondition(plist["GMInputSource"] as? Int == port.ddc)
            precondition(plist["GMMonitorSerial"] as? String == "Test EDID")
            precondition(plist["GMBluetoothAddress"] == nil)
            precondition(plist["NSBluetoothAlwaysUsageDescription"] == nil)
            precondition(plist["NSBluetoothPeripheralUsageDescription"] == nil)
            precondition(plist["LSUIElement"] as? Bool == true)
            precondition(plist["CFBundleName"] as? String == destination.deletingPathExtension().lastPathComponent)
            let current = plist["CFBundleIdentifier"] as! String
            if let identifier { precondition(identifier == current) }
            identifier = current
            let executable = destination.appendingPathComponent("Contents/MacOS/InputShortcutRunner")
            precondition(fm.isExecutableFile(atPath: executable.path))
            let process = Process()
            process.executableURL = executable
            try process.run()
            process.waitUntilExit()
            precondition(process.terminationStatus == 0)
        }
        let dp = MonitorInput.ports.first { $0.name == "DP" }!
        func export(_ url: URL, replacing: Bool = true, serial: String = "Test EDID", address: Data? = nil) throws {
            try InputShortcutExporter.export(port: dp, serial: serial, bluetoothAddress: address, to: url,
                                             replaceExisting: replacing, sourceBundle: source)
        }
        let address = Data([0x0A, 0xB2, 0x3C, 0x04, 0x5E, 0x6F])
        for serial in ["Test EDID", ""] {
            try export(destination, serial: serial, address: address)
            let plist = try info(destination)
            precondition(plist["GMMonitorSerial"] as? String == serial)
            precondition(plist["GMBluetoothAddress"] as? String == "0A:B2:3C:04:5E:6F")
            precondition(!(plist["NSBluetoothAlwaysUsageDescription"] as? String ?? "").isEmpty)
            precondition(!(plist["NSBluetoothPeripheralUsageDescription"] as? String ?? "").isEmpty)
            precondition(plist["CFBundleIdentifier"] as? String == identifier)
        }
        refuses { try export(source) }
        refuses { try export(destination, replacing: false) }
        refuses { try export(destination, serial: " ") }
        refuses { try export(destination, serial: "invalid\0serial") }
        refuses { try export(destination, serial: "invalid\0serial", address: address) }
        refuses { try export(destination, serial: "", address: Data([0xAB])) }
        refuses { try export(destination, address: Data(repeating: 0xAB, count: 7)) }
        let foreign = root.appendingPathComponent("切换到DP.app")
        try fm.createDirectory(at: foreign, withIntermediateDirectories: false)
        let marker = Data("untouched".utf8)
        try marker.write(to: foreign.appendingPathComponent("marker"))
        refuses { try export(foreign) }
        let unrelatedFile = root.appendingPathComponent("document.app")
        try marker.write(to: unrelatedFile)
        refuses { try export(unrelatedFile) }
        let link = root.appendingPathComponent("link.app")
        try fm.createSymbolicLink(at: link, withDestinationURL: destination)
        refuses { try export(link) }
        let broken = root.appendingPathComponent("dangling.app")
        try fm.createSymbolicLink(at: broken, withDestinationURL: root.appendingPathComponent("missing"))
        refuses { try export(broken) }
        try fm.removeItem(at: helper)
        refuses { try export(destination) }
        let after = try info(destination)
        precondition(after["CFBundleIdentifier"] as? String == identifier)
        precondition(after["GMInputSource"] as? Int == dp.ddc)
        precondition(after["GMBluetoothAddress"] as? String == "0A:B2:3C:04:5E:6F")
        let protectedData = try Data(contentsOf: foreign.appendingPathComponent("marker"))
        let protectedFile = try Data(contentsOf: unrelatedFile)
        precondition(protectedData == marker && protectedFile == marker)
        let remaining = try fm.contentsOfDirectory(atPath: root.path)
        precondition(!remaining.contains { $0.hasPrefix(".redmagic-export-") })
        print("PASS: four inputs, DDC and Bluetooth bindings, privacy descriptions, identity across replacement, protected files and failure recovery")
    }
}
