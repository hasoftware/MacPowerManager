// Ký file cập nhật (.zip) bằng khóa Ed25519, ghi chữ ký base64 ra <file>.sig.
//   UPDATE_SIGNING_KEY=<base64> swift scripts/sign-update.swift <file.zip>
// Dùng trong workflow Release; app kiểm tra chữ ký bằng khóa công khai trong UpdateSignature.swift.
import CryptoKit
import Foundation

guard CommandLine.arguments.count == 2,
      let keyText = ProcessInfo.processInfo.environment["UPDATE_SIGNING_KEY"],
      let keyData = Data(base64Encoded: keyText.trimmingCharacters(in: .whitespacesAndNewlines)),
      let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: keyData) else {
    FileHandle.standardError.write("Cần biến môi trường UPDATE_SIGNING_KEY hợp lệ và đường dẫn file.\n".data(using: .utf8)!)
    exit(1)
}
let file = URL(fileURLWithPath: CommandLine.arguments[1])
let signature = try key.signature(for: Data(contentsOf: file))
try Data(signature.base64EncodedString().utf8).write(to: file.appendingPathExtension("sig"))
print("Đã ký \(file.lastPathComponent)")
