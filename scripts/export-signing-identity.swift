import Foundation
import Security
import CryptoKit

// Export only the identity matching the repository's public certificate.
func check(_ result: OSStatus, operation: String) throws {
    if result != errSecSuccess {
        throw NSError(domain: NSOSStatusErrorDomain, code: Int(result),
                      userInfo: [NSLocalizedDescriptionKey: "\(operation) failed (OSStatus \(result))"])
    }
}
do {
    let certificateData = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
    var keychain: SecKeychain?
    try check(SecKeychainOpen(NSHomeDirectory() + "/Library/Keychains/login.keychain-db", &keychain), operation: "Open login keychain")
    var matches: CFTypeRef?
    try check(SecItemCopyMatching([
        kSecClass: kSecClassIdentity,
        kSecMatchSearchList: [keychain!],
        kSecReturnRef: true,
        kSecMatchLimit: kSecMatchLimitAll
    ] as CFDictionary, &matches), operation: "Find signing identities")
    let identities = matches as? [SecIdentity] ?? []
    guard let identity = identities.first(where: { candidate in
        var certificate: SecCertificate?
        return SecIdentityCopyCertificate(candidate, &certificate) == errSecSuccess &&
            certificate.map { SecCertificateCopyData($0) as Data == certificateData } == true
    }) else {
        throw NSError(domain: "ocrsnip", code: 1, userInfo: [NSLocalizedDescriptionKey: "The fixed ocrsnip identity is missing"])
    }
    let password = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0).base64EncodedString() } as CFString
    var parameters = SecItemImportExportKeyParameters(
        version: UInt32(SEC_KEY_IMPORT_EXPORT_PARAMS_VERSION), flags: [],
        passphrase: Unmanaged.passUnretained(password), alertTitle: nil, alertPrompt: nil,
        accessRef: nil, keyUsage: nil, keyAttributes: nil
    )
    var exported: CFData?
    try check(SecItemExport(identity, .formatPKCS12, [], &parameters, &exported), operation: "Export fixed signing identity")
    guard let exported else { fatalError("No identity was exported") }
    for (path, data) in [(CommandLine.arguments[2], exported as Data),
                         (CommandLine.arguments[3], Data((password as String).utf8))] {
        guard FileManager.default.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            fatalError("Could not save encrypted export")
        }
    }
    print("Exported only the fixed ocrsnip identity; private files have mode 0600")
} catch {
    fputs("\(error.localizedDescription)\n", stderr)
    exit(1)
}
