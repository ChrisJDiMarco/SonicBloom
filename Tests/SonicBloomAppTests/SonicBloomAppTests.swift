import XCTest
import AudioToolbox
import Foundation
import SonicBloomCore
@testable import SonicBloomApp

final class SonicBloomAppTests: XCTestCase {
    func testRecoveryAgentAutostartBuildsInstallCommandForBundlePath() {
        let scriptURL = URL(fileURLWithPath: "/Applications/SonicBloom.app/Contents/Resources/install_recovery_agent.sh")
        let bundleURL = URL(fileURLWithPath: "/Applications/SonicBloom.app")

        let command = RecoveryAgentAutostart.command(scriptURL: scriptURL, appBundleURL: bundleURL)

        XCTAssertEqual(command.executableURL, scriptURL)
        XCTAssertEqual(command.arguments, [bundleURL.path])
    }

    func testAppLaunchInstallsBundledRecoveryAgent() throws {
        let delegate = try String(contentsOf: URL(fileURLWithPath: "Sources/SonicBloomApp/SonicBloomAppDelegate.swift"))
        let buildScript = try String(contentsOf: URL(fileURLWithPath: "Scripts/build_app.sh"))

        XCTAssertTrue(delegate.contains("RecoveryAgentAutostart.installBundledAgentIfAvailable()"))
        XCTAssertTrue(buildScript.contains("install_recovery_agent.sh"))
        XCTAssertTrue(buildScript.contains("$contents/Resources/install_recovery_agent.sh"))
    }

    func testAppBundleShipsLocalizedPermissionCopy() throws {
        let buildScript = try String(contentsOf: URL(fileURLWithPath: "Scripts/build_app.sh"))
        let infoPlistStrings = try String(contentsOf: URL(fileURLWithPath: "Sources/SonicBloomApp/Resources/en.lproj/InfoPlist.strings"))

        XCTAssertTrue(buildScript.contains("Sources/SonicBloomApp/Resources/en.lproj"))
        XCTAssertTrue(infoPlistStrings.contains("NSMicrophoneUsageDescription"))
        XCTAssertTrue(infoPlistStrings.contains("not to listen to your physical microphone"))
    }

    @MainActor
    func testSelectedPresetWinsOverSuggestedForegroundAppPreset() {
        let suiteName = "SonicBloomAppTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let viewModel = SonicBloomViewModel.testInstance(defaults: defaults)

        viewModel.setForegroundAppBundleIdentifierForTesting("com.google.Chrome")
        viewModel.profileAudioRefreshCountForTesting = 0
        viewModel.selectedPreset = .deepBass

        XCTAssertEqual(viewModel.processingPresetForTesting.name, DSPPreset.deepBass.name)
        XCTAssertEqual(viewModel.profileAudioRefreshCountForTesting, 0)
    }

    @MainActor
    func testForegroundAppSwitchDoesNotChangeLiveSyncMode() {
        let suiteName = "SonicBloomAppTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let viewModel = SonicBloomViewModel.testInstance(defaults: defaults)
        viewModel.settings = SonicBloomSettings(syncMode: .music)

        viewModel.setForegroundAppBundleIdentifierForTesting("com.spotify.client")
        XCTAssertEqual(viewModel.processingSyncModeForTesting, .music)

        viewModel.setForegroundAppBundleIdentifierForTesting("com.google.Chrome")
        XCTAssertEqual(viewModel.processingSyncModeForTesting, .music)
    }

    @MainActor
    func testSavedAppRuleDoesNotOverrideMasterPreset() {
        let suiteName = "SonicBloomAppTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let viewModel = SonicBloomViewModel.testInstance(defaults: defaults)

        viewModel.profile.upsert(AppAudioRule(
            bundleIdentifier: "com.google.Chrome",
            displayName: "Chrome",
            isMuted: true,
            presetName: DSPPreset.spokenVoice.name
        ))
        viewModel.setForegroundAppBundleIdentifierForTesting("com.google.Chrome")
        viewModel.selectedPreset = .deepBass

        XCTAssertEqual(viewModel.processingPresetForTesting.name, DSPPreset.deepBass.name)
        XCTAssertGreaterThan(viewModel.processingPresetForTesting.outputGainDB, -60)
    }

    @MainActor
    func testAppProfileCanApplyToForegroundAppWhenEnabled() {
        let suiteName = "SonicBloomAppTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let viewModel = SonicBloomViewModel.testInstance(defaults: defaults)

        viewModel.profile.upsert(AppAudioRule(
            bundleIdentifier: "com.google.Chrome",
            displayName: "Chrome",
            gainDB: -3,
            presetName: DSPPreset.spokenVoice.name
        ))
        viewModel.settings = SonicBloomSettings(applyAppProfilesAutomatically: true)
        viewModel.setForegroundAppBundleIdentifierForTesting("com.google.Chrome")
        viewModel.selectedPreset = .deepBass

        XCTAssertEqual(viewModel.processingPresetForTesting.name, DSPPreset.spokenVoice.name)
        XCTAssertLessThan(viewModel.processingPresetForTesting.outputGainDB, DSPPreset.spokenVoice.outputGainDB)
    }

    @MainActor
    func testAutomaticAppProfilesIgnoreUnsavedSuggestions() {
        let suiteName = "SonicBloomAppTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let viewModel = SonicBloomViewModel.testInstance(defaults: defaults)

        viewModel.settings = SonicBloomSettings(applyAppProfilesAutomatically: true)
        viewModel.setForegroundAppBundleIdentifierForTesting("com.google.Chrome")
        viewModel.selectedPreset = .deepBass

        XCTAssertEqual(viewModel.processingPresetForTesting.name, DSPPreset.deepBass.name)
    }

    @MainActor
    func testImportedAutoEQProfileAppliesToSelectedPreset() throws {
        let suiteName = "SonicBloomAppTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let viewModel = SonicBloomViewModel.testInstance(defaults: defaults)
        viewModel.selectedPreset = .flat

        try viewModel.importAutoEQProfile(
            name: "HD 650 AutoEQ",
            text: "GraphicEQ: 20 -4; 1000 2; 20000 3"
        )

        XCTAssertEqual(viewModel.selectedPreset.name, DSPPreset.manual.name)
        XCTAssertLessThan(viewModel.selectedPreset.eqBandsDB[0], -3)
        XCTAssertGreaterThan(viewModel.selectedPreset.eqBandsDB[17], 1.5)
        XCTAssertTrue(viewModel.availableHeadphoneProfiles.contains { $0.name == "HD 650 AutoEQ" })
    }

    @MainActor
    func testImportedParametricAutoEQProfileAppliesToSelectedPreset() throws {
        let suiteName = "SonicBloomAppTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let viewModel = SonicBloomViewModel.testInstance(defaults: defaults)
        viewModel.selectedPreset = .flat

        try viewModel.importAutoEQProfile(
            name: "Parametric AutoEQ",
            text: """
            Preamp: -4.0 dB
            Filter 1: ON PK Fc 80 Hz Gain -5.0 dB Q 0.70
            Filter 2: ON PK Fc 1000 Hz Gain 2.5 dB Q 1.41
            """
        )

        XCTAssertLessThan(viewModel.selectedPreset.eqBandsDB[6], -4)
        XCTAssertGreaterThan(viewModel.selectedPreset.eqBandsDB[17], 2)
        XCTAssertEqual(viewModel.selectedPreset.outputGainDB, -4)
        XCTAssertTrue(viewModel.availableHeadphoneProfiles.contains { $0.name == "Parametric AutoEQ" })
    }

    @MainActor
    func testViewModelImportsAutoEQProfileFolder() throws {
        let suiteName = "SonicBloomAppTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let viewModel = SonicBloomViewModel.testInstance(defaults: defaults)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SonicBloomAutoEQ-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try "Frequency,Gain\n20,-3\n1000,2\n20000,3\n".write(
            to: directory.appendingPathComponent("AirPods.csv"),
            atomically: true,
            encoding: .utf8
        )
        try "GraphicEQ: 20 -4; 1000 1; 20000 4".write(
            to: directory.appendingPathComponent("HD 650.txt"),
            atomically: true,
            encoding: .utf8
        )

        try viewModel.importAutoEQProfiles(from: directory)

        XCTAssertTrue(viewModel.availableHeadphoneProfiles.contains { $0.name == "AirPods" })
        XCTAssertTrue(viewModel.availableHeadphoneProfiles.contains { $0.name == "HD 650" })
        XCTAssertEqual(viewModel.selectedPreset.name, DSPPreset.manual.name)
    }

    @MainActor
    func testViewModelRemovesImportedHeadphoneProfiles() throws {
        let suiteName = "SonicBloomAppTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let viewModel = SonicBloomViewModel.testInstance(defaults: defaults)

        try viewModel.importAutoEQProfile(
            name: "HD 650 AutoEQ",
            text: "GraphicEQ: 20 -4; 1000 2; 20000 3"
        )
        viewModel.removeCustomHeadphoneProfile("imported-hd-650-autoeq")

        XCTAssertFalse(viewModel.availableHeadphoneProfiles.contains { $0.name == "HD 650 AutoEQ" })
    }

    @MainActor
    func testViewModelStoresAudioUnitEffectsInProfile() {
        let suiteName = "SonicBloomAppTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let viewModel = SonicBloomViewModel.testInstance(defaults: defaults)
        let effect = AudioUnitEffectDescriptor(
            name: "Studio EQ",
            manufacturerName: "Apple",
            componentType: kAudioUnitType_Effect,
            componentSubType: fourCC("eqal"),
            componentManufacturer: fourCC("appl")
        )

        viewModel.addAudioUnitEffect(effect)
        viewModel.setAudioUnitEffectEnabled("aufx-eqal-appl", false)
        viewModel.removeAudioUnitEffect("missing")

        XCTAssertEqual(viewModel.profile.audioUnitEffects.count, 1)
        XCTAssertEqual(viewModel.profile.audioUnitEffects.first?.isEnabled, false)

        viewModel.removeAudioUnitEffect("aufx-eqal-appl")
        XCTAssertEqual(viewModel.profile.audioUnitEffects, [])
    }

    @MainActor
    func testViewModelPublishesAvailableAudioUnitEffects() {
        let suiteName = "SonicBloomAppTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let effect = AudioUnitEffectDescriptor(
            name: "Studio EQ",
            manufacturerName: "Apple",
            componentType: kAudioUnitType_Effect,
            componentSubType: fourCC("eqal"),
            componentManufacturer: fourCC("appl")
        )
        let viewModel = SonicBloomViewModel.testInstance(
            defaults: defaults,
            audioUnitEffectLoader: { [effect] }
        )

        XCTAssertEqual(viewModel.availableAudioUnitEffects, [effect])

        viewModel.addAudioUnitEffect(effect)
        XCTAssertEqual(viewModel.profile.audioUnitEffects.map(\.effect), [effect])
    }

    @MainActor
    func testViewModelRejectsAudioUnitEffectsThatCannotInstantiate() {
        let suiteName = "SonicBloomAppTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let effect = AudioUnitEffectDescriptor(
            name: "Broken Effect",
            manufacturerName: "Test",
            componentType: kAudioUnitType_Effect,
            componentSubType: fourCC("fail"),
            componentManufacturer: fourCC("test")
        )
        let viewModel = SonicBloomViewModel.testInstance(
            defaults: defaults,
            audioUnitEffectPreflight: { _ in false }
        )

        viewModel.addAudioUnitEffect(effect)

        XCTAssertEqual(viewModel.profile.audioUnitEffects, [])
        XCTAssertEqual(viewModel.lastError, "Broken Effect could not be loaded as an Audio Unit effect.")
    }

    func testAudioUnitHostChainLoadsEnabledEffectsInOrder() {
        let eq = AudioUnitEffectDescriptor(
            name: "Studio EQ",
            manufacturerName: "Apple",
            componentType: kAudioUnitType_Effect,
            componentSubType: fourCC("eqal"),
            componentManufacturer: fourCC("appl")
        )
        let broken = AudioUnitEffectDescriptor(
            name: "Broken",
            manufacturerName: "Apple",
            componentType: kAudioUnitType_Effect,
            componentSubType: fourCC("fail"),
            componentManufacturer: fourCC("appl")
        )
        let output = AudioUnitEffectDescriptor(
            name: "Output",
            manufacturerName: "Apple",
            componentType: kAudioUnitType_Output,
            componentSubType: fourCC("outp"),
            componentManufacturer: fourCC("appl")
        )
        var loaded: [String] = []
        let chain = AudioUnitEffectHostChain(loader: { effect, _ in
            guard effect.id != broken.id else { return nil }
            loaded.append(effect.id)
            return NSObject()
        })

        chain.update(
            slots: [
                AudioUnitEffectSlot(effect: eq),
                AudioUnitEffectSlot(effect: broken),
                AudioUnitEffectSlot(effect: output)
            ],
            sampleRate: 48_000
        )

        XCTAssertEqual(loaded, [eq.id])
        XCTAssertEqual(chain.activeEffectIDs, [eq.id])
        XCTAssertEqual(chain.failedEffectIDs, [broken.id])
    }

    func testAudioBridgeOwnsAudioUnitHostChain() {
        let effect = AudioUnitEffectDescriptor(
            name: "Studio EQ",
            manufacturerName: "Apple",
            componentType: kAudioUnitType_Effect,
            componentSubType: fourCC("eqal"),
            componentManufacturer: fourCC("appl")
        )
        let chain = AudioUnitEffectHostChain(loader: { _, _ in NSObject() })
        let bridge = SonicBloomAudioBridge(audioUnitHost: chain)

        let failed = bridge.updateAudioUnitEffects([AudioUnitEffectSlot(effect: effect)])

        XCTAssertEqual(failed, [])
        XCTAssertEqual(bridge.activeAudioUnitEffectIDsForTesting, [effect.id])
        XCTAssertEqual(bridge.failedAudioUnitEffectIDsForTesting, [])
    }

    @MainActor
    func testSmartMeterDoesNotChangeMasterPreset() {
        let suiteName = "SonicBloomAppTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let viewModel = SonicBloomViewModel.testInstance(defaults: defaults)
        viewModel.settings = SonicBloomSettings(smartPresetMatching: true)
        viewModel.isBridgeRunning = true
        viewModel.selectedPreset = .deepBass

        for _ in 0..<6 {
            viewModel.handleMeterForTesting(DSPMeter(lowEnergy: 0.14, midEnergy: 0.20, highEnergy: 0.18))
        }

        XCTAssertEqual(viewModel.selectedPreset.name, DSPPreset.deepBass.name)
    }

    @MainActor
    func testRawCompareOnlyTogglesWhileProcessing() {
        let suiteName = "SonicBloomAppTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let viewModel = SonicBloomViewModel.testInstance(defaults: defaults)

        viewModel.toggleRawCompare()
        XCTAssertFalse(viewModel.isBypassed)

        viewModel.isBridgeRunning = true
        viewModel.toggleRawCompare()
        XCTAssertTrue(viewModel.isBypassed)

        viewModel.toggleRawCompare()
        XCTAssertFalse(viewModel.isBypassed)
    }

    @MainActor
    func testViewModelLoadsSavesImportsAndExportsCustomPresets() throws {
        let suiteName = "SonicBloomAppTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PresetStore(directoryURL: directory)
        let savedPreset = DSPPreset.manual.with(name: "Desk Speakers", bassAmount: 0.45)
        try store.saveCustomPreset(savedPreset)
        let viewModel = SonicBloomViewModel.testInstance(defaults: defaults, presetStore: store)

        XCTAssertTrue(viewModel.presets.contains(savedPreset))

        viewModel.selectedPreset = DSPPreset.manual.with(name: "Movie Night", hrtfAmount: 0.5)
        try viewModel.saveSelectedPresetAsCustom()
        XCTAssertTrue(viewModel.presets.contains { $0.name == "Movie Night" })

        let exported = try viewModel.exportSelectedPresetData()
        let importedPreset = DSPPreset.manual.with(name: "Imported Voice", fidelityAmount: 0.4)
        let importedData = try JSONEncoder().encode(PresetShareDocument(preset: importedPreset))
        try viewModel.importPreset(from: importedData)

        XCTAssertEqual(try JSONDecoder().decode(PresetShareDocument.self, from: exported).preset.name, "Movie Night")
        XCTAssertEqual(viewModel.selectedPreset.name, importedPreset.name)
        XCTAssertTrue(viewModel.presets.contains(importedPreset))
    }

    @MainActor
    func testCheckForUpdatesPublishesAvailableManifest() async throws {
        let suiteName = "SonicBloomAppTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let packageURL = try XCTUnwrap(URL(string: "https://example.com/SonicBloom-0.2.0.pkg"))
        let manifest = SonicBloomUpdateManifest(
            version: "0.2.0",
            minimumSystemVersion: "13.0",
            packageURL: packageURL,
            packageSHA256: SonicBloomUpdatePackageVerifier.sha256Hex(for: Data("pkg".utf8)),
            notes: "Fixes"
        )
        let viewModel = SonicBloomViewModel.testInstance(
            defaults: defaults,
            currentVersion: "0.1.0",
            updateManifestLoader: { _ in manifest }
        )

        await viewModel.checkForUpdates()

        XCTAssertEqual(viewModel.updateStatusText, "Update 0.2.0 available")
        XCTAssertEqual(viewModel.updateDownloadURL, packageURL)
    }

    @MainActor
    func testCheckForUpdatesRejectsMissingPackageChecksum() async throws {
        let suiteName = "SonicBloomAppTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let manifest = SonicBloomUpdateManifest(
            version: "0.2.0",
            minimumSystemVersion: "13.0",
            packageURL: URL(string: "https://example.com/SonicBloom-0.2.0.pkg")!
        )
        let viewModel = SonicBloomViewModel.testInstance(
            defaults: defaults,
            currentVersion: "0.1.0",
            updateManifestLoader: { _ in manifest }
        )

        await viewModel.checkForUpdates()

        XCTAssertEqual(viewModel.updateStatusText, "Update package checksum missing")
        XCTAssertNil(viewModel.updateDownloadURL)
    }

    @MainActor
    func testCheckForUpdatesRejectsInvalidPackageChecksum() async throws {
        let suiteName = "SonicBloomAppTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let manifest = SonicBloomUpdateManifest(
            version: "0.2.0",
            minimumSystemVersion: "13.0",
            packageURL: URL(string: "https://example.com/SonicBloom-0.2.0.pkg")!,
            packageSHA256: "abc123"
        )
        let viewModel = SonicBloomViewModel.testInstance(
            defaults: defaults,
            currentVersion: "0.1.0",
            updateManifestLoader: { _ in manifest }
        )

        await viewModel.checkForUpdates()

        XCTAssertEqual(viewModel.updateStatusText, "Update package checksum invalid")
        XCTAssertNil(viewModel.updateDownloadURL)
    }

    @MainActor
    func testCheckForUpdatesRejectsNonPackageInstallerURL() async throws {
        let suiteName = "SonicBloomAppTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let manifest = SonicBloomUpdateManifest(
            version: "0.2.0",
            minimumSystemVersion: "13.0",
            packageURL: URL(string: "https://example.com/SonicBloom.zip")!,
            packageSHA256: SonicBloomUpdatePackageVerifier.sha256Hex(for: Data("pkg".utf8))
        )
        let viewModel = SonicBloomViewModel.testInstance(
            defaults: defaults,
            currentVersion: "0.1.0",
            updateManifestLoader: { _ in manifest }
        )

        await viewModel.checkForUpdates()

        XCTAssertEqual(viewModel.updateStatusText, "Update package must be a .pkg installer")
        XCTAssertNil(viewModel.updateDownloadURL)
    }

    @MainActor
    func testCheckForUpdatesRejectsInvalidReleaseVersion() async throws {
        let suiteName = "SonicBloomAppTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let manifest = SonicBloomUpdateManifest(
            version: "1.0/evil",
            minimumSystemVersion: "13.0",
            packageURL: URL(string: "https://example.com/SonicBloom.pkg")!,
            packageSHA256: SonicBloomUpdatePackageVerifier.sha256Hex(for: Data("pkg".utf8))
        )
        let viewModel = SonicBloomViewModel.testInstance(
            defaults: defaults,
            currentVersion: "0.1.0",
            updateManifestLoader: { _ in manifest }
        )

        await viewModel.checkForUpdates()

        XCTAssertEqual(viewModel.updateStatusText, "Update version invalid")
        XCTAssertNil(viewModel.updateDownloadURL)
    }

    @MainActor
    func testCheckForUpdatesRejectsUnsupportedMacOSManifest() async throws {
        let suiteName = "SonicBloomAppTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let packageURL = try XCTUnwrap(URL(string: "https://example.com/SonicBloom-0.2.0.pkg"))
        let manifest = SonicBloomUpdateManifest(
            version: "0.2.0",
            minimumSystemVersion: "99.0",
            packageURL: packageURL,
            packageSHA256: "abc123",
            notes: "Fixes"
        )
        let viewModel = SonicBloomViewModel.testInstance(
            defaults: defaults,
            currentVersion: "0.1.0",
            updateManifestLoader: { _ in manifest }
        )

        await viewModel.checkForUpdates()

        XCTAssertEqual(viewModel.updateStatusText, "Update 0.2.0 requires macOS 99.0")
        XCTAssertNil(viewModel.updateDownloadURL)
    }

    @MainActor
    func testCheckForUpdatesRejectsInsecurePackageURL() async throws {
        let suiteName = "SonicBloomAppTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let packageURL = try XCTUnwrap(URL(string: "http://example.com/SonicBloom-0.2.0.pkg"))
        let manifest = SonicBloomUpdateManifest(
            version: "0.2.0",
            minimumSystemVersion: "13.0",
            packageURL: packageURL,
            packageSHA256: "abc123",
            notes: "Fixes"
        )
        let viewModel = SonicBloomViewModel.testInstance(
            defaults: defaults,
            currentVersion: "0.1.0",
            updateManifestLoader: { _ in manifest }
        )

        await viewModel.checkForUpdates()

        XCTAssertEqual(viewModel.updateStatusText, "Update package URL must use HTTPS")
        XCTAssertNil(viewModel.updateDownloadURL)
    }

    @MainActor
    func testDownloadUpdateVerifiesChecksumBeforeOpeningInstaller() async throws {
        let suiteName = "SonicBloomAppTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let packageData = Data("verified package".utf8)
        let packageURL = try XCTUnwrap(URL(string: "https://example.com/SonicBloom-0.2.0.pkg"))
        let manifest = SonicBloomUpdateManifest(
            version: "0.2.0",
            minimumSystemVersion: "13.0",
            packageURL: packageURL,
            packageSHA256: SonicBloomUpdatePackageVerifier.sha256Hex(for: packageData),
            notes: "Fixes"
        )
        let packageDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: packageDirectory) }
        let viewModel = SonicBloomViewModel.testInstance(
            defaults: defaults,
            currentVersion: "0.1.0",
            updateManifestLoader: { _ in manifest },
            updatePackageDownloader: { url in
                XCTAssertEqual(url, packageURL)
                return packageData
            },
            updatePackageDirectory: packageDirectory
        )

        await viewModel.checkForUpdates()
        await viewModel.downloadVerifiedUpdate()

        let localURL = try XCTUnwrap(viewModel.verifiedUpdatePackageURL)
        XCTAssertEqual(try Data(contentsOf: localURL), packageData)
        XCTAssertEqual(viewModel.updateStatusText, "Update package verified")
    }

    @MainActor
    func testDownloadUpdateUsesSafeLocalPackageName() async throws {
        let suiteName = "SonicBloomAppTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let packageData = Data("verified package".utf8)
        let manifest = SonicBloomUpdateManifest(
            version: "1.0.0",
            minimumSystemVersion: "13.0",
            packageURL: URL(string: "https://example.com/SonicBloom.pkg")!,
            packageSHA256: SonicBloomUpdatePackageVerifier.sha256Hex(for: packageData)
        )
        let packageDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: packageDirectory) }
        let viewModel = SonicBloomViewModel.testInstance(
            defaults: defaults,
            currentVersion: "0.1.0",
            updateManifestLoader: { _ in manifest },
            updatePackageDownloader: { _ in packageData },
            updatePackageDirectory: packageDirectory
        )

        await viewModel.checkForUpdates()
        await viewModel.downloadVerifiedUpdate()

        let localURL = try XCTUnwrap(viewModel.verifiedUpdatePackageURL)
        XCTAssertEqual(localURL.deletingLastPathComponent(), packageDirectory)
        XCTAssertEqual(localURL.lastPathComponent, "SonicBloom-1.0.0.pkg")
    }

    @MainActor
    func testDownloadUpdateRejectsManifestWithoutChecksum() async throws {
        let suiteName = "SonicBloomAppTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var downloadAttempted = false
        let packageURL = try XCTUnwrap(URL(string: "https://example.com/SonicBloom-0.2.0.pkg"))
        let manifest = SonicBloomUpdateManifest(
            version: "0.2.0",
            minimumSystemVersion: "13.0",
            packageURL: packageURL,
            notes: "Fixes"
        )
        let viewModel = SonicBloomViewModel.testInstance(
            defaults: defaults,
            currentVersion: "0.1.0",
            updateManifestLoader: { _ in manifest },
            updatePackageDownloader: { _ in
                downloadAttempted = true
                return Data()
            }
        )

        await viewModel.checkForUpdates()
        await viewModel.downloadVerifiedUpdate()

        XCTAssertFalse(downloadAttempted)
        XCTAssertNil(viewModel.verifiedUpdatePackageURL)
        XCTAssertEqual(viewModel.updateStatusText, "Update package checksum missing")
    }

    func testPerAppMixerLeavesRoomForRouteActionTray() {
        XCTAssertGreaterThanOrEqual(
            PerAppMixerLayout.bottomScrollClearance,
            PerAppMixerLayout.routeActionTrayHeight + PerAppMixerLayout.sectionSpacing
        )
        XCTAssertGreaterThanOrEqual(
            PerAppMixerLayout.panelHeight,
            PerAppMixerLayout.minimumPanelHeight(visibleRows: 4)
        )
    }

    func testCustomAudioControlsExposeVoiceOverAdjustment() throws {
        let controlPanel = try String(contentsOf: URL(fileURLWithPath: "Sources/SonicBloomApp/SonicBloomControlPanel.swift"))

        XCTAssertTrue(controlPanel.contains(".accessibilityAdjustableAction"))
        XCTAssertTrue(controlPanel.contains("VoiceOver increment and decrement"))
        XCTAssertTrue(controlPanel.contains(".accessibilityLabel(title)"))
        XCTAssertTrue(controlPanel.contains(".accessibilityValue(label)"))
    }

    func testBridgeEnqueuesPerAppFramesIntoPlaybackRing() {
        let bridge = SonicBloomAudioBridge()
        bridge.prepareRingForTesting(capacity: 8)

        bridge.enqueueAppFrames([StereoFrame(left: 0.25, right: -0.5)], observedCallbackFrames: 1)

        XCTAssertEqual(bridge.drainFramesForTesting(count: 1), [
            StereoFrame(left: 0.25, right: -0.5)
        ])
        bridge.stop()
    }

    @MainActor
    func testViewModelExposesSupportDiagnosticsReport() {
        let suiteName = "SonicBloomAppTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let viewModel = SonicBloomViewModel.testInstance(defaults: defaults)

        viewModel.selectedPreset = .movies
        viewModel.handleMeterForTesting(DSPMeter(inputPeak: 0.2, outputPeak: 0.3, gainReductionDB: 1.5, limitedSamples: 7))

        XCTAssertTrue(viewModel.diagnosticsReport.contains("SonicBloom Diagnostics"))
        XCTAssertTrue(viewModel.diagnosticsReport.contains("Preset: Movies"))
        XCTAssertTrue(viewModel.diagnosticsReport.contains("Output: Test Speakers"))
        XCTAssertTrue(viewModel.diagnosticsReport.contains("Clips Protected: 7"))
    }

    func testSettingsExposeCopyDiagnosticsAction() throws {
        let controlPanel = try String(contentsOf: URL(fileURLWithPath: "Sources/SonicBloomApp/SonicBloomControlPanel.swift"))

        XCTAssertTrue(controlPanel.contains("Copy Diagnostics"))
        XCTAssertTrue(controlPanel.contains("viewModel.copyDiagnosticsReport()"))
    }
}

private extension SonicBloomViewModel {
    @MainActor
    static func testInstance(
        defaults: UserDefaults,
        currentVersion: String = "0.1.0",
        updateManifestLoader: @escaping (URL) async throws -> SonicBloomUpdateManifest = { _ in
            SonicBloomUpdateManifest(
                version: "0.1.0",
                minimumSystemVersion: "13.0",
                packageURL: URL(string: "https://example.com/SonicBloom.pkg")!
            )
        },
        updatePackageDownloader: @escaping (URL) async throws -> Data = { _ in Data() },
        updatePackageDirectory: URL = FileManager.default.temporaryDirectory,
        audioUnitEffectLoader: @escaping () -> [AudioUnitEffectDescriptor] = { [] },
        audioUnitEffectPreflight: @escaping (AudioUnitEffectDescriptor) -> Bool = { _ in true },
        presetStore: PresetStore = PresetStore(directoryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true))
    ) -> SonicBloomViewModel {
        SonicBloomViewModel(
            defaults: defaults,
            routeState: .testReady,
            startLiveContext: false,
            currentVersion: currentVersion,
            updateManifestLoader: updateManifestLoader,
            updatePackageDownloader: updatePackageDownloader,
            updatePackageDirectory: updatePackageDirectory,
            audioUnitEffectLoader: audioUnitEffectLoader,
            audioUnitEffectPreflight: audioUnitEffectPreflight,
            presetStore: presetStore
        )
    }
}

private extension AudioRouteState {
    static let testReady = AudioRouteState(
        virtualDeviceName: "SonicBloom Output",
        bridgeInputDeviceID: 1,
        bridgeInputDeviceName: "SonicBloom Output",
        selectedPhysicalOutputID: 2,
        selectedPhysicalOutputName: "Test Speakers",
        sampleRate: 48_000,
        channels: 2,
        bufferSize: 64,
        installHealth: .active,
        statusMessage: "Test route ready."
    )
}

private func fourCC(_ value: String) -> OSType {
    value.utf8.reduce(OSType(0)) { ($0 << 8) | OSType($1) }
}
