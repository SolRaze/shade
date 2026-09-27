import Foundation
import IcliKit
import IcliPrivate
import IcliSystem

// MARK: - LiveContainer

extension GuestAPI {
    static func executeLiveContainer(_ method: String, _ params: [String: Any]) throws -> [String: Any]? {
        guard method == "apps.lc_install" else { return nil }
        let path = try string(params, "path")
        defer { try? FileManager.default.removeItem(atPath: path) }
        return try installIntoLiveContainer(ipa: path, container: optionalString(params, "bundle_id") ?? "com.kdt.livecontainer")
    }

    /// Unpacks the IPA's .app into LiveContainer's Documents/Applications.
    /// LiveContainer patches and signs the bundle itself on first launch, so the
    /// bundle is only moved in place and handed to mobile. An existing bundle of
    /// the same name is replaced; its LCAppInfo.plist carries over so the app
    /// keeps its LiveContainer data folder.
    private static func installIntoLiveContainer(ipa: String, container: String) throws -> [String: Any] {
        let manager = FileManager.default
        guard let data = try appDataDir(container)["data_path"] as? String, !data.isEmpty else {
            throw GuestAPIError.operationFailed("\(container) has no data container, launch it once first")
        }
        let apps = data + "/Documents/Applications"
        let stage = NSTemporaryDirectory() + UUID().uuidString
        try manager.createDirectory(atPath: stage, withIntermediateDirectories: true)
        defer { try? manager.removeItem(atPath: stage) }
        _ = try decodeBridgeJSON(takeCString(icli_extract_ipa_json(ipa, stage)), "IPA extraction response")

        let payload = stage + "/Payload"
        guard let name = try manager.contentsOfDirectory(atPath: payload).first(where: { $0.hasSuffix(".app") }),
              let id = NSDictionary(contentsOfFile: "\(payload)/\(name)/Info.plist")?["CFBundleIdentifier"] as? String
        else {
            throw GuestAPIError.operationFailed("IPA does not contain an .app payload with a CFBundleIdentifier")
        }
        let source = "\(payload)/\(name)", target = "\(apps)/\(name)"
        try manager.createDirectory(
            atPath: apps,
            withIntermediateDirectories: true,
            attributes: [.ownerAccountID: 501, .groupOwnerAccountID: 501],
        )
        try? manager.copyItem(atPath: target + "/LCAppInfo.plist", toPath: source + "/LCAppInfo.plist")
        let replaced = manager.fileExists(atPath: target)
        if replaced {
            try manager.removeItem(atPath: target)
        }
        try manager.moveItem(atPath: source, toPath: target)
        lchown(target, 501, 501)
        for case let relative as String in manager.enumerator(atPath: target) ?? .init() {
            lchown("\(target)/\(relative)", 501, 501)
        }
        return ["msg": "\(replaced ? "Replaced" : "Added") \(name) (\(id)) in \(container)", "bundle_id": id]
    }
}
