import Darwin
import Foundation

enum InputShortcutExporter {
    private static let runner = "InputShortcutRunner"
    private static let identifierPrefix = "com.local.redmagic-display.shortcut."

    static func export(port: MonitorInput, serial: String, to destination: URL,
                       replaceExisting: Bool = false, sourceBundle: URL = Bundle.main.bundleURL) throws {
        let serial = serial.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !serial.isEmpty, !serial.utf8.contains(0) else {
            throw DisplayError("请先绑定有效的显示器 DDC 序列号，再导出快捷方式。")
        }
        guard MonitorInput.ports.contains(where: { $0.ddc == port.ddc }),
              destination.isFileURL, destination.pathExtension.lowercased() == "app" else {
            throw DisplayError("请选择有效的输入源，并将快捷方式保存为 .app。")
        }
        let target = destination.standardizedFileURL
        let sourcePath = sourceBundle.resolvingSymlinksInPath().standardizedFileURL.path
        let targetPath = target.resolvingSymlinksInPath().standardizedFileURL.path
        guard targetPath != sourcePath, !targetPath.hasPrefix(sourcePath + "/") else {
            throw DisplayError("请选择主应用以外的位置保存快捷方式。")
        }

        let manager = FileManager.default
        let original = try fileInfo(at: target)
        var identifier = identifierPrefix + UUID().uuidString.lowercased()
        if let original {
            guard replaceExisting, original.st_mode & S_IFMT == S_IFDIR,
                  let existingID = exportedIdentifier(at: target) else {
                throw DisplayError("目标已存在。请选择新名称，或替换本程序先前导出的快捷方式。")
            }
            identifier = existingID
        }

        let staging = target.deletingLastPathComponent()
            .appendingPathComponent(".redmagic-export-" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false,
                                    attributes: [.posixPermissions: 0o700])
        // Only a displaced, concurrently changed destination may need to be kept for recovery.
        var removeStaging = true
        defer { if removeStaging { try? manager.removeItem(at: staging) } }
        let candidate = staging.appendingPathComponent("Shortcut.app", isDirectory: true)
        let contents = candidate.appendingPathComponent("Contents", isDirectory: true)
        let binaries = contents.appendingPathComponent("MacOS", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        let helper = sourceBundle.appendingPathComponent("Contents/Helpers/" + runner)
        guard let helperInfo = try fileInfo(at: helper), helperInfo.st_mode & S_IFMT == S_IFREG,
              manager.isExecutableFile(atPath: helper.path) else {
            throw DisplayError("主应用中的快捷方式启动器缺失或无法运行，请重新安装主应用。")
        }
        try manager.createDirectory(at: binaries, withIntermediateDirectories: true)
        try manager.createDirectory(at: resources, withIntermediateDirectories: false)
        try manager.copyItem(at: helper, to: binaries.appendingPathComponent(runner))
        for name in ["AppIcon.icns", "LICENSE.txt", "m1ddc-LICENSE.txt"] {
            try manager.copyItem(at: sourceBundle.appendingPathComponent("Contents/Resources/" + name),
                                 to: resources.appendingPathComponent(name))
        }
        let name = target.deletingPathExtension().lastPathComponent
        let info: [String: Any] = [
            "CFBundlePackageType": "APPL", "CFBundleName": name, "CFBundleDisplayName": name,
            "CFBundleIdentifier": identifier, "CFBundleExecutable": runner, "CFBundleIconFile": "AppIcon",
            "CFBundleShortVersionString": "1.0", "CFBundleVersion": "1", "LSUIElement": true,
            "LSMinimumSystemVersion": "14.0", "NSHighResolutionCapable": true,
            "GMShortcutFormat": 1, "GMInputSource": port.ddc, "GMMonitorSerial": serial
        ]
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        try codesign(["--force", "--sign", "-", candidate.path])
        try codesign(["--verify", "--strict", candidate.path])

        guard let original else {
            // A second exporter or the Finder may have created the path during signing.
            guard renamex_np(candidate.path, target.path, UInt32(RENAME_EXCL)) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return
        }
        guard let prepared = try fileInfo(at: candidate),
              sameFile(try fileInfo(at: target), original) else {
            throw DisplayError("保存期间目标已更改，请重新选择。")
        }
        guard renamex_np(candidate.path, target.path, UInt32(RENAME_SWAP)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        // The displaced item is now in staging. Never delete an unexpected item,
        // even if an uncoordinated writer changed the target during the swap.
        removeStaging = false
        guard sameFile(try fileInfo(at: candidate), original) else {
            if sameFile(try fileInfo(at: target), prepared),
               renamex_np(candidate.path, target.path, UInt32(RENAME_SWAP)) == 0,
               sameFile(try fileInfo(at: candidate), prepared) {
                removeStaging = true
                throw DisplayError("保存期间目标已更改，请重新选择。")
            }
            throw DisplayError("保存期间目标已被其他程序替换。原文件已保留在 " + candidate.path)
        }
        removeStaging = true
    }

    private static func fileInfo(at url: URL) throws -> stat? {
        var info = stat()
        if lstat(url.path, &info) == 0 { return info }
        if errno == ENOENT { return nil }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    private static func sameFile(_ current: stat?, _ original: stat) -> Bool {
        current?.st_dev == original.st_dev && current?.st_ino == original.st_ino
    }

    private static func exportedIdentifier(at url: URL) -> String? {
        let plist = url.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              info["GMShortcutFormat"] as? Int == 1,
              info["CFBundleExecutable"] as? String == runner,
              let id = info["CFBundleIdentifier"] as? String, id.hasPrefix(identifierPrefix),
              UUID(uuidString: String(id.dropFirst(identifierPrefix.count))) != nil else { return nil }
        return id
    }

    private static func codesign(_ arguments: [String]) throws {
        let process = Process()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = arguments
        process.standardError = errors
        try process.run()
        let diagnostic = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let details = String(decoding: diagnostic, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw DisplayError("快捷方式签名校验失败。" + details)
        }
    }
}
