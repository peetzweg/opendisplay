import Foundation

let root = "/Users/cyh/Documents/opendisplay"
let logPath = "\(root)/build-run/open-display-launcher.log"

func runProcess(_ executable: String, _ arguments: [String]) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    do {
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    } catch {
        return 1
    }
}

func notify(_ message: String) {
    _ = runProcess("/usr/bin/osascript", [
        "-e",
        "display notification \"\(message)\" with title \"OpenDisplay 启动器\""
    ])
}

func showFailureDialog() {
    _ = runProcess("/usr/bin/osascript", [
        "-e",
        "display dialog \"OpenDisplay 启动失败。将为你定位日志文件。\" buttons {\"好\"} default button \"好\" with title \"OpenDisplay 启动器\""
    ])
}

do {
    try FileManager.default.createDirectory(
        atPath: "\(root)/build-run",
        withIntermediateDirectories: true
    )

    let header = """
    [\(Date())] OpenDisplay 启动器开始运行
    项目路径：\(root)
    日志路径：\(logPath)

    """
    try header.write(toFile: logPath, atomically: true, encoding: .utf8)

    let logHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: logPath))
    try logHandle.seekToEnd()
    defer { try? logHandle.close() }

    notify("正在构建并启动 OpenDisplay...")

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "\(root)/script/build_and_run.sh")
    process.currentDirectoryURL = URL(fileURLWithPath: root)
    process.environment = [
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/Applications/Xcode.app/Contents/Developer/usr/bin",
        "HOME": NSHomeDirectory()
    ]
    process.standardOutput = logHandle
    process.standardError = logHandle

    try process.run()
    process.waitUntilExit()

    if process.terminationStatus == 0 {
        notify("OpenDisplay 已启动，请查看菜单栏图标。")
        exit(0)
    }

    showFailureDialog()
    _ = runProcess("/usr/bin/open", ["-R", logPath])
    exit(process.terminationStatus)
} catch {
    try? "启动器自身失败：\(error)\n".write(toFile: logPath, atomically: true, encoding: .utf8)
    showFailureDialog()
    _ = runProcess("/usr/bin/open", ["-R", logPath])
    exit(1)
}
