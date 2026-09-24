@testable import VPhoneCore
import Foundation
import Testing

/// Needs only `ldid` and `ditto`, no iOS SDK: a signature does not care that the
/// binary inside the fake .app is a host executable.
struct IPASignerTests {
    @Test func signsTheAppInsideAnIPAAndGivesItTrollStoreEntitlements() throws {
        let resources = VPhoneResources.resolve()
        guard let ldid = resources.ldid,
              FileManager.default.fileExists(atPath: resources.signcert.path) else { return }

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let stage = scratch.appendingPathComponent("stage")
        let app = stage.appendingPathComponent("Payload/Test.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: "/bin/echo"), to: app.appendingPathComponent("Test"))
        try PropertyListSerialization
            .data(fromPropertyList: [
                "CFBundleIdentifier": "com.example.test",
                "CFBundleExecutable": "Test",
            ], format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Info.plist"))

        let ipa = scratch.appendingPathComponent("Test.ipa")
        try Process.run(URL(fileURLWithPath: "/usr/bin/ditto"),
                        arguments: ["-c", "-k", "--sequesterRsrc",
                                    stage.path,
                                    ipa.path]).waitUntilExit()

        let signed = try VPhoneIPASigner.sign(ipa: ipa, certificate: resources.signcert)
        defer { try? FileManager.default.removeItem(at: signed.scratch) }
        #expect(FileManager.default.fileExists(atPath: signed.ipa.path))

        let entitlements = try dump(ldid: ldid, binary: signed.scratch
            .appendingPathComponent("root/Payload/Test.app/Test"))
        #expect(entitlements.contains("jb.pmap_cs_custom_trust"))
        #expect(entitlements.contains("TROLLTROLL"))
    }

    private func dump(ldid: URL, binary: URL) throws -> String {
        let process = Process()
        process.executableURL = ldid
        process.arguments = ["-e", binary.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
