// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Tailnet
import WispCommon

// One binary: the app when launched with no arguments (from Finder or `open`), or the CLI. A copy of
// it inside a generated phantom app bundle (Info.plist has WispPhantom) runs as that phantom app.
// Each kind of process logs to its own file (WispCommon/Log.swift): wisp.log (the app), phantom-<App>.log
// (a phantom), cli.log (the CLI commands).
atexit { Log.flush() }
Tailnet.log = { debug, message in if debug { Log.debug(.tailnet, message) } else { Log.info(.tailnet, message) } }
if let phantom = Bundle.main.infoDictionary?[Brand.phantomInfoKey] as? [String: Any] {
    Log.fileName = phantomLogFileName(phantom["appName"] as? String ?? ProcessInfo.processInfo.processName)
    runPhantom(phantom)
}

let arguments = Array(CommandLine.arguments.dropFirst())
func cli<T>(_ f: ([String]) -> T) {
    Log.fileName = "cli.log"
    Log.debug(.cli, "\(Brand.cli) \(arguments.joined(separator: " ")) (\(Diagnostics.versionLine))")
    _ = f(Array(arguments.dropFirst()))
}
switch arguments.first {
case "send": cli(runSend)
case "view": cli(runView)
case "poke": cli(runPoke)
case "e2e": cli(runE2E)
case "vdisplay-test": cli(runVirtualDisplayTest)
case "tailnet": cli(runTailnet)
case "diagnostics":
    Log.fileName = "cli.log"
    Log.echoToStderr = Log.verbose // the report goes to stdout; log lines would only clutter it
    print(Diagnostics.report())
case "help", "-h", "--help": print(usage)
case nil, "--connect": runApp()
// Launch arguments macOS and Xcode add on their own (-NSDocumentRevisionsDebugMode YES, -psn_0_…, -Apple…).
case let a? where a.hasPrefix("-NS") || a.hasPrefix("-psn_") || a.hasPrefix("-Apple"): runApp()
// Anything else is a mistyped command: say so instead of starting the app (which once ran a real
// settings migration during a test that only wanted the usage text).
case let a?:
    FileHandle.standardError.write(Data("\(Brand.cli): unknown command \"\(a)\"\n\n\(usage)\n".utf8))
    exit(2)
}
