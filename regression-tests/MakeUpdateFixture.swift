import CryptoKit
import Foundation

// Disposable test key, never used for a release or written to the login keychain.
let key = Curve25519.Signing.PrivateKey()
let destination = CommandLine.arguments[1]
let infoURL = URL(fileURLWithPath: CommandLine.arguments[2]).appendingPathComponent("Contents/Info.plist")
var info = try PropertyListSerialization.propertyList(from: Data(contentsOf: infoURL), format: nil) as! [String: Any]
info["SUPublicEDKey"] = key.publicKey.rawRepresentation.base64EncodedString()
try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: infoURL)
guard FileManager.default.createFile(atPath: destination,
    contents: Data(key.rawRepresentation.base64EncodedString().utf8),
    attributes: [.posixPermissions: 0o600]) else {
    fatalError("Could not create disposable test key")
}
