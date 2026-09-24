import Foundation

/// Re-signs an IPA on the host before it goes to the guest.
///
/// vphoned can sign what it installs, but only with an iOS `ldid` that is
/// already on the device, and nothing puts one there: neither an iOS base nor
/// the procursus bootstrap carries `ldid`, so on a fresh VM the guest has
/// nothing to sign with. The host always does — `make build` refuses to run
/// without it — and a code signature does not depend on which machine produced
/// it, so signing here and installing there is equivalent.
///
/// Every entitlement decision mirrors `vp_sign_app` in
/// `scripts/vphoned/vphoned_install.m`. Keep the two in step: a guest that
/// signs for itself must land on the same result.
public enum VPhoneIPASigner {
    public enum SignError: Error, CustomStringConvertible {
        case noPayload
        case ldidFailed(String)
        case commandFailed(String, Int32, String)

        public var description: String {
            switch self {
            case .noPayload: "IPA does not contain a Payload/*.app bundle"
            case let .ldidFailed(output): "ldid failed: \(output)"
            case let .commandFailed(tool, code, output):
                "\(tool) exited \(code)\(output.isEmpty ? "" : ": \(output)")"
            }
        }
    }

    /// Entitlements for an app whose binary carries none. TrollStore's values:
    /// a bare app still needs an application-identifier and a keychain group or
    /// the installed app cannot reach its own keychain items.
    private static var fallbackEntitlements: [String: Any] {
        [
            "application-identifier": "TROLLTROLL.*",
            "com.apple.developer.team-identifier": "TROLLTROLL",
            "get-task-allow": true,
            "keychain-access-groups": ["TROLLTROLL.*", "com.apple.token"],
        ]
    }

    /// Signs the app inside `ipa` and writes a new IPA. Returns the new file and
    /// the scratch directory the caller must delete once it has been uploaded.
    public static func sign(ipa: URL, certificate: URL?) throws -> (ipa: URL, scratch: URL) {
        guard let ldid = VPhoneResources.resolve().ldid else {
            throw SignError.ldidFailed("no ldid on this host (brew install ldid-procursus)")
        }

        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vphone-sign-\(UUID().uuidString)")
        let extracted = scratch.appendingPathComponent("root")
        do {
            try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
            try run("/usr/bin/ditto", ["-x", "-k", ipa.path, extracted.path])

            guard let app = appBundle(in: extracted.appendingPathComponent("Payload")) else {
                throw SignError.noPayload
            }
            try sign(app: app, ldid: ldid, certificate: certificate)

            let signed = scratch.appendingPathComponent(ipa.lastPathComponent)
            // No --keepParent: the guest's extractor expects Payload/ at the
            // archive root, the way a real IPA is laid out.
            try run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", extracted.path, signed.path])
            return (signed, scratch)
        } catch {
            try? FileManager.default.removeItem(at: scratch)
            throw error
        }
    }

    // MARK: - Signing

    private static func sign(app: URL, ldid: URL, certificate: URL?) throws {
        let fm = FileManager.default
        // Path, not URL: the enumerator's URLs spell the same file differently.
        let mainExecutable = executable(ofBundleAt: app)?.resolvingSymlinksInPath().path

        // Every nested bundle that ships its own executable needs its own
        // entitlements; a framework inherits the app's and is left to the
        // recursive pass.
        let enumerator = fm.enumerator(at: app, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            guard url.lastPathComponent == "Info.plist",
                  let info = NSDictionary(contentsOf: url) as? [String: Any],
                  let bundleID = info["CFBundleIdentifier"] as? String, !bundleID.isEmpty,
                  info["CFBundlePackageType"] as? String != "FMWK",
                  let name = info["CFBundleExecutable"] as? String, !name.isEmpty
            else { continue }

            let binary = url.deletingLastPathComponent().appendingPathComponent(name)
            guard fm.fileExists(atPath: binary.path) else { continue }

            var entitlements = dumpEntitlements(binary: binary, ldid: ldid)
            if entitlements == nil, binary.resolvingSymlinksInPath().path == mainExecutable {
                entitlements = fallbackEntitlements
            }
            try signBinary(
                binary, entitlements: patched(entitlements ?? [:], bundleID: bundleID),
                ldid: ldid, certificate: certificate
            )
        }

        // Signs everything the walk skipped — frameworks, dylibs, helpers.
        try signBinary(app, entitlements: nil, ldid: ldid, certificate: certificate)
    }

    private static func patched(_ entitlements: [String: Any], bundleID: String) -> [String: Any] {
        var out = entitlements
        // A container-required already naming a container is left alone; false
        // means the app opted out, and an app running without a container or a
        // sandbox must not be handed one.
        var writeContainer = true
        if out["com.apple.private.security.container-required"] is String {
            writeContainer = false
        } else if let flag = out["com.apple.private.security.container-required"] as? Bool {
            writeContainer = flag
        }
        let noContainer = out["com.apple.private.security.no-container"] as? Bool ?? false
        let noSandbox = out["com.apple.private.security.no-sandbox"] as? Bool ?? false
        if writeContainer, !noContainer, !noSandbox {
            out["com.apple.private.security.container-required"] = bundleID
        }
        // Tells the JB kernel's page-mapping trust to treat the signature as an
        // App Store one; without it the app is killed on launch.
        out["jb.pmap_cs_custom_trust"] = "PMAP_CS_APP_STORE"
        return out
    }

    private static func signBinary(
        _ path: URL, entitlements: [String: Any]?, ldid: URL, certificate: URL?
    ) throws {
        var args: [String] = []
        var entitlementsFile: URL?
        if let entitlements,
           let xml = try? PropertyListSerialization.data(
               fromPropertyList: entitlements, format: .xml, options: 0
           )
        {
            let file = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("\(UUID().uuidString).plist")
            try xml.write(to: file)
            entitlementsFile = file
            args.append("-S\(file.path)")
        } else {
            args.append("-S")
        }
        if let certificate {
            args.append("-M")
            args.append("-K\(certificate.path)")
        }
        args.append(path.path)

        defer { entitlementsFile.map { try? FileManager.default.removeItem(at: $0) } }
        do {
            try run(ldid.path, args)
        } catch let SignError.commandFailed(_, _, output) {
            throw SignError.ldidFailed(output)
        }
    }

    /// The binary's current entitlements, or nil when it carries none.
    private static func dumpEntitlements(binary: URL, ldid: URL) -> [String: Any]? {
        guard let output = try? run(ldid.path, ["-e", binary.path]),
              let data = output.data(using: .utf8), !data.isEmpty,
              let plist = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil
              ) as? [String: Any],
              !plist.isEmpty
        else { return nil }
        return plist
    }

    // MARK: - Helpers

    private static func appBundle(in payload: URL) -> URL? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: payload.path)) ?? []
        guard let app = names.first(where: { ($0 as NSString).pathExtension == "app" }) else {
            return nil
        }
        return payload.appendingPathComponent(app)
    }

    private static func executable(ofBundleAt bundle: URL) -> URL? {
        guard let info = NSDictionary(contentsOf: bundle.appendingPathComponent("Info.plist"))
            as? [String: Any],
            let name = info["CFBundleExecutable"] as? String, !name.isEmpty
        else { return nil }
        return bundle.appendingPathComponent(name)
    }

    @discardableResult
    private static func run(_ tool: String, _ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw SignError.commandFailed(
                (tool as NSString).lastPathComponent, process.terminationStatus,
                output.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return output
    }
}
