// Tạo cặp khóa Ed25519 để ký bản cập nhật (chỉ chạy một lần khi thiết lập dự án).
//   swift scripts/generate-update-key.swift <file-khóa-bí-mật>
// Khóa bí mật (base64) được ghi vào file đó với quyền 600; hãy đưa nó vào GitHub Secrets (UPDATE_SIGNING_KEY)
// và sao lưu cẩn thận. Khóa công khai in ra màn hình, dán vào Sources/PowerCore/Updates/UpdateSignature.swift.
// Mất khóa bí mật thì các bản sau không ký được: người dùng phải tải thủ công một lần để nhận khóa công khai mới.
import CryptoKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write("Cách dùng: generate-update-key.swift <file-khóa-bí-mật>\n".data(using: .utf8)!)
    exit(1)
}
let url = URL(fileURLWithPath: CommandLine.arguments[1])
guard !FileManager.default.fileExists(atPath: url.path) else {
    FileHandle.standardError.write("Đã có \(url.path), không ghi đè.\n".data(using: .utf8)!)
    exit(1)
}
let key = Curve25519.Signing.PrivateKey()
try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
FileManager.default.createFile(atPath: url.path, contents: Data(key.rawRepresentation.base64EncodedString().utf8),
                               attributes: [.posixPermissions: 0o600])
print(key.publicKey.rawRepresentation.base64EncodedString())
