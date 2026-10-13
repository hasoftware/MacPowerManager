import CryptoKit
import Foundation

/// Xác minh chữ ký Ed25519 của bản cập nhật. Workflow Release ký file .zip bằng khóa bí mật (GitHub Secrets
/// `UPDATE_SIGNING_KEY`, xem scripts/sign-update.swift); app chỉ cài bản có chữ ký khớp khóa công khai dưới đây,
/// nên kể cả khi ai đó thay file trên trang Release, app cũng không cài.
public enum UpdateSignature {
    /// Khóa công khai Ed25519 (base64) của HASOFTWARE.
    public static let publicKey = "l7sHkJyHibVzG28dYt3TLc0cBtlitlYW1ia/oFWLIF0="

    public static func isValid(_ data: Data, signature: String, publicKey: String = publicKey) -> Bool {
        guard let keyData = Data(base64Encoded: publicKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              let signatureData = Data(base64Encoded: signature.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return false }
        return key.isValidSignature(signatureData, for: data)
    }
}
