import Foundation
import Security

/// Thông tin chữ ký của một app: Team ID và App Group khai trong entitlement.
public struct SigningInfo: Sendable, Equatable {
    public var teamID: String?
    /// `com.apple.security.application-groups` nguyên văn (vd `UBF8T346G9.Office`, `group.com.foo`).
    public var appGroups: [String]

    public init(teamID: String? = nil, appGroups: [String] = []) {
        self.teamID = teamID
        self.appGroups = appGroups
    }
}

/// Seam đọc chữ ký (test dùng bản giả: bundle trong cây giả không có chữ ký).
public protocol SigningInfoReader: Sendable {
    /// `path` là đường dẫn VẬT LÝ của bundle. Không có chữ ký / lỗi → nil.
    func signingInfo(atPath path: String) -> SigningInfo?
}

/// Đọc bằng Security (`SecStaticCode`), không xác thực chữ ký - chỉ đọc, vài ms mỗi app.
public struct SecuritySigningInfoReader: SigningInfoReader {
    public init() {}

    public func signingInfo(atPath path: String) -> SigningInfo? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess,
              let code else { return nil }
        var raw: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &raw) == errSecSuccess,
              let dict = raw as? [String: Any] else { return nil }
        let team = dict[kSecCodeInfoTeamIdentifier as String] as? String
        let ents = dict[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
        let groups = ents?["com.apple.security.application-groups"] as? [String] ?? []
        if team == nil, groups.isEmpty { return nil }
        return SigningInfo(teamID: team, appGroups: groups)
    }
}

/// Không đọc chữ ký (test không cần).
public struct NoSigningInfoReader: SigningInfoReader {
    public init() {}
    public func signingInfo(atPath path: String) -> SigningInfo? { nil }
}
