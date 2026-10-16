import AppKit
import Sparkle

/// A real Sparkle check against a loopback feed; never downloads or installs an app.
@MainActor
final class UpdateProbe: NSObject, SPUUpdaterDelegate {
    var foundVersion: String?
    var finished = false
    var error: Error?

    func feedURLString(for updater: SPUUpdater) -> String? { CommandLine.arguments[1] }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        foundVersion = item.versionString
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        self.error = error
        finished = true
    }
}

@main
struct Test {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        defer {
            if let identifier = Bundle.main.bundleIdentifier {
                UserDefaults.standard.removePersistentDomain(forName: identifier)
            }
        }
        let probe = UpdateProbe()
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: probe, userDriverDelegate: nil)
        try controller.updater.start()
        controller.updater.checkForUpdateInformation()
        let deadline = Date().addingTimeInterval(20)
        while !probe.finished && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        guard probe.finished else { fatalError("Update check timed out") }
        let expected = CommandLine.arguments[2]
        let errorCode = (probe.error as NSError?)?.code
        let passed: Bool
        switch expected {
        case "update": passed = probe.foundVersion == CommandLine.arguments[3] && probe.error == nil
        case "current": passed = probe.foundVersion == nil && errorCode == Int(SUError.noUpdateError.rawValue)
        case "rejected": passed = probe.foundVersion == nil && probe.error != nil && errorCode != Int(SUError.noUpdateError.rawValue)
        default: fatalError("Unknown expectation")
        }
        guard passed else {
            print("FAIL: expected \(expected), found=\(String(describing: probe.foundVersion)), error=\(String(describing: probe.error))")
            exit(1)
        }
        print("PASS: Sparkle \(expected) (version=\(probe.foundVersion ?? "none"), error=\(String(describing: errorCode)))")
    }
}
