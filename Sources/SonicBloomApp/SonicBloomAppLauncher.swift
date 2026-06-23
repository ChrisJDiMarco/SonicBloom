import AppKit

@MainActor
private var retainedDelegate: SonicBloomAppDelegate?

@MainActor
public func runSonicBloomApp() {
    let app = NSApplication.shared
    let delegate = SonicBloomAppDelegate()
    retainedDelegate = delegate
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
