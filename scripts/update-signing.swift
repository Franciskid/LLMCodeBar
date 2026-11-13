// Signs release disk images so LLMCodeBar only installs updates made with this key.
//
//   update-signing public-key      print the public key to paste into Updater.swift
//   update-signing sign <file>     write <file>.sig next to it
//   update-signing verify <file> <public key>
//                                  check <file>.sig against a public key, as the app does
//
// The private key lives in the login keychain ("LLMCodeBar update signing key") and is
// created the first time it's needed. Back it up: without it, installed copies will
// refuse every future update.
import CryptoKit
import Foundation
import Security

let service = "LLMCodeBar update signing key"
let account = "ed25519"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func storedKey() -> Curve25519.Signing.PrivateKey? {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
        kSecReturnData as String: true,
    ]
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = item as? Data else { fail("Couldn't read the signing key from the keychain (\(status)).") }
    guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) else { fail("The keychain item isn't an Ed25519 key.") }
    return key
}

func signingKey() -> Curve25519.Signing.PrivateKey {
    if let key = storedKey() { return key }
    let key = Curve25519.Signing.PrivateKey()
    let item: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
        kSecAttrLabel as String: service,
        kSecValueData as String: key.rawRepresentation,
    ]
    let status = SecItemAdd(item as CFDictionary, nil)
    guard status == errSecSuccess else { fail("Couldn't save the new signing key to the keychain (\(status)).") }
    FileHandle.standardError.write(Data("Created a new signing key in the login keychain. Back it up.\n".utf8))
    return key
}

let arguments = CommandLine.arguments.dropFirst()
switch arguments.first {
case "public-key":
    print(signingKey().publicKey.rawRepresentation.base64EncodedString())
case "sign":
    guard let path = arguments.dropFirst().first else { fail("usage: update-signing sign <file>") }
    guard let data = FileManager.default.contents(atPath: path) else { fail("Can't read \(path).") }
    let signature = try signingKey().signature(for: data)
    try Data(signature.base64EncodedString().utf8).write(to: URL(fileURLWithPath: path + ".sig"))
    print(path + ".sig")
case "verify":
    let rest = Array(arguments.dropFirst())
    guard rest.count == 2 else { fail("usage: update-signing verify <file> <public key>") }
    guard let data = FileManager.default.contents(atPath: rest[0]),
          let text = try? String(contentsOfFile: rest[0] + ".sig", encoding: .utf8),
          let signature = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          let keyData = Data(base64Encoded: rest[1]),
          let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
          key.isValidSignature(signature, for: data) else { fail("\(rest[0]).sig doesn't verify against \(rest[1]).") }
    print("Verified \(rest[0]).sig")
default:
    fail("usage: update-signing public-key | sign <file> | verify <file> <public key>")
}
