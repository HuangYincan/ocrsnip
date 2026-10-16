import CryptoKit
import Foundation

final class EnclosureParser: NSObject, XMLParserDelegate {
    var signature: String?
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        if name == "enclosure" { signature = attributes["sparkle:edSignature"] }
    }
}

let infoURL = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("Contents/Info.plist")
let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: infoURL), format: nil) as! [String: Any]
let parser = XMLParser(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))!
let delegate = EnclosureParser()
parser.delegate = delegate
guard parser.parse(), let encodedSignature = delegate.signature,
      let signature = Data(base64Encoded: encodedSignature),
      let encodedKey = info["SUPublicEDKey"] as? String,
      let keyData = Data(base64Encoded: encodedKey) else {
    fatalError("Missing update signature or embedded public key")
}
let key = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
let archive = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]), options: .mappedIfSafe)
guard key.isValidSignature(signature, for: archive) else {
    fputs("FAIL: update archive signature does not match the application's public key\n", stderr)
    exit(1)
}
print("PASS: update archive is authenticated by the application's embedded public key")
