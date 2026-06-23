import Foundation

struct RecoveryAgentInstallCommand: Equatable {
    var executableURL: URL
    var arguments: [String]
}

enum RecoveryAgentAutostart {
    static func command(scriptURL: URL, appBundleURL: URL) -> RecoveryAgentInstallCommand {
        RecoveryAgentInstallCommand(executableURL: scriptURL, arguments: [appBundleURL.path])
    }

    static func installBundledAgentIfAvailable(bundle: Bundle = .main) {
        guard let resourceURL = bundle.resourceURL else { return }
        let scriptURL = resourceURL.appendingPathComponent("install_recovery_agent.sh")
        guard FileManager.default.isExecutableFile(atPath: scriptURL.path) else { return }
        let installCommand = command(scriptURL: scriptURL, appBundleURL: bundle.bundleURL)

        DispatchQueue.global(qos: .utility).async {
            run(installCommand)
        }
    }

    private static func run(_ command: RecoveryAgentInstallCommand) {
        let process = Process()
        process.executableURL = command.executableURL
        process.arguments = command.arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {}
    }
}
