// Creates a stable, machine-local code-signing identity for development builds.
// The private key stays in Keychain; only public certificate data is encoded here.
// Legacy file-keychain APIs are needed for codesign's per-application key access.
// No trust settings, keychain search lists, or privacy permissions are changed.
import CryptoKit
import Foundation
import Security

private let identityName = "MacDuo Local Development"
private let keyTag = Data("de.luke.macduo.local-signing.v1".utf8)

private struct SigningError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private func check(_ status: OSStatus, _ action: String) throws {
    guard status == errSecSuccess else {
        let description = SecCopyErrorMessageString(status, nil) as String? ?? String(status)
        throw SigningError(message: "\(action): \(description)")
    }
}

private func keychain() throws -> SecKeychain {
    var result: SecKeychain?
    if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--keychain" {
        try check(SecKeychainOpen(CommandLine.arguments[2], &result), "Open signing keychain")
    } else if CommandLine.arguments.count == 1 {
        try check(SecKeychainCopyDefault(&result), "Find your default keychain")
    } else {
        throw SigningError(message: "Usage: local-signing.swift [--keychain PATH]")
    }
    guard let result else { throw SigningError(message: "No signing keychain is available.") }
    return result
}

private func keychainPath(_ keychain: SecKeychain) throws -> String {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    var length = UInt32(buffer.count)
    try check(SecKeychainGetPath(keychain, &length, &buffer), "Read signing keychain path")
    return String(cString: buffer)
}

private func existingCertificate(in keychain: SecKeychain) throws -> SecCertificate? {
    let query: [CFString: Any] = [
        kSecClass: kSecClassCertificate, kSecAttrLabel: identityName,
        kSecMatchSearchList: [keychain], kSecMatchLimit: kSecMatchLimitAll,
        kSecReturnRef: true
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    try check(status, "Find local signing certificate")
    guard let certificates = result as? [SecCertificate], certificates.count == 1,
          let certificate = certificates.first,
          SecCertificateCopySubjectSummary(certificate) as String? == identityName else {
        throw SigningError(message: "Multiple or unexpected MacDuo signing certificates were found. Select one explicitly with MACDUO_SIGNING_IDENTITY.")
    }
    var identity: SecIdentity?
    try check(SecIdentityCreateWithCertificate(keychain, certificate, &identity),
              "Find the existing signing key; the certificate will not be silently replaced")
    return certificate
}

// Minimal DER encoding for a self-signed RSA X.509 certificate. No private key
// bytes are requested or written. Security.framework performs the signature.
private func der(_ tag: UInt8, _ content: Data) -> Data {
    var count = content.count
    var length: [UInt8] = []
    if count < 128 {
        length = [UInt8(count)]
    } else {
        while count > 0 { length.insert(UInt8(count & 255), at: 0); count >>= 8 }
        length.insert(0x80 | UInt8(length.count), at: 0)
    }
    return Data([tag] + length) + content
}

private func sequence(_ values: Data...) -> Data { der(0x30, values.reduce(Data(), +)) }
private func oid(_ bytes: [UInt8]) -> Data { der(0x06, Data(bytes)) }
private let sha256RSA = sequence(oid([0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 1, 1, 11]), der(5, Data()))
private let rsa = sequence(oid([0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 1, 1, 1]), der(5, Data()))

private func certificateDate(_ date: Date) -> Data {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = formatter.timeZone
    let shortYear = calendar.component(.year, from: date) < 2050
    formatter.dateFormat = shortYear ? "yyMMddHHmmss'Z'" : "yyyyMMddHHmmss'Z'"
    return der(shortYear ? 0x17 : 0x18, Data(formatter.string(from: date).utf8))
}

private func createCertificate(in keychain: SecKeychain) throws -> SecCertificate {
    // An incomplete setup must not cause an identity change on a later build.
    let keyQuery: [CFString: Any] = [
        kSecClass: kSecClassKey, kSecAttrApplicationTag: keyTag,
        kSecMatchSearchList: [keychain]
    ]
    let previousKey = SecItemCopyMatching(keyQuery as CFDictionary, nil)
    guard previousKey == errSecItemNotFound else {
        if previousKey != errSecSuccess { try check(previousKey, "Check local signing key") }
        throw SigningError(message: "A MacDuo signing key exists without its certificate. Restore that certificate or select MACDUO_SIGNING_IDENTITY; no replacement key was created.")
    }

    var error: Unmanaged<CFError>?
    let attributes: [CFString: Any] = [
        kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 3072
    ]
    guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
        if let error { throw error.takeRetainedValue() }
        throw SigningError(message: "Could not generate the local signing key.")
    }
    guard let publicKey = SecKeyCopyPublicKey(privateKey),
          let publicData = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
        if let error { throw error.takeRetainedValue() }
        throw SigningError(message: "Could not read the public signing key.")
    }
    var serial = [UInt8](repeating: 0, count: 16)
    try check(SecRandomCopyBytes(kSecRandomDefault, serial.count, &serial), "Generate certificate serial")
    serial[0] = (serial[0] & 0x7f) | 1
    let name = sequence(der(0x31, sequence(oid([0x55, 4, 3]), der(0x0c, Data(identityName.utf8)))))
    let validity = sequence(certificateDate(Date().addingTimeInterval(-86400)),
                            certificateDate(Date().addingTimeInterval(10 * 365.25 * 86400)))
    let constraints = sequence(oid([0x55, 0x1d, 0x13]), der(1, Data([0xff])), der(4, sequence()))
    let usage = sequence(oid([0x55, 0x1d, 0x0f]), der(1, Data([0xff])), der(4, der(3, Data([7, 0x80]))))
    let extendedUsage = sequence(oid([0x55, 0x1d, 0x25]), der(4, sequence(oid([0x2b, 6, 1, 5, 5, 7, 3, 3]))))
    let body = sequence(der(0xa0, der(2, Data([2]))), der(2, Data(serial)), sha256RSA,
                        name, validity, name, sequence(rsa, der(3, Data([0]) + publicData)),
                        der(0xa3, sequence(constraints, usage, extendedUsage)))
    guard let signature = SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256,
                                                body as CFData, &error) as Data? else {
        if let error { throw error.takeRetainedValue() }
        throw SigningError(message: "Could not sign the local certificate.")
    }
    let encoded = sequence(body, sha256RSA, der(3, Data([0]) + signature))
    guard let certificate = SecCertificateCreateWithData(nil, encoded as CFData) else {
        throw SigningError(message: "Could not read the generated signing certificate.")
    }

    var codesign: SecTrustedApplication?
    try check(SecTrustedApplicationCreateFromPath("/usr/bin/codesign", &codesign), "Configure codesign access")
    var access: SecAccess?
    try check(SecAccessCreate(identityName as CFString, [codesign!] as CFArray, &access), "Create signing key access policy")
    // Store the key object directly with a codesign-only access list. No private
    // key representation is exported; normal Keychain export policy is retained.
    let key: [CFString: Any] = [
        kSecClass: kSecClassKey, kSecValueRef: privateKey, kSecAttrKeyClass: kSecAttrKeyClassPrivate,
        kSecAttrLabel: identityName, kSecAttrApplicationTag: keyTag,
        kSecAttrApplicationLabel: Data(Insecure.SHA1.hash(data: publicData)),
        kSecAttrIsPermanent: true, kSecUseKeychain: keychain, kSecAttrAccess: access!
    ]
    try check(SecItemAdd(key as CFDictionary, nil), "Store local signing key")
    var complete = false
    defer { if !complete { _ = SecItemDelete(keyQuery as CFDictionary) } }
    try check(SecItemAdd([
        kSecClass: kSecClassCertificate, kSecValueRef: certificate,
        kSecAttrLabel: identityName, kSecUseKeychain: keychain
    ] as CFDictionary, nil), "Store local signing certificate")
    complete = true
    FileHandle.standardError.write(Data("Created a persistent MacDuo development identity in your keychain.\n".utf8))
    return certificate
}

do {
    let store = try keychain()
    let certificate = try existingCertificate(in: store) ?? createCertificate(in: store)
    // SHA-1 here is the public certificate selector required by codesign. The
    // actual certificate and code signatures use SHA-256.
    let fingerprint = Insecure.SHA1.hash(data: SecCertificateCopyData(certificate) as Data)
        .map { String(format: "%02X", $0) }.joined()
    print(fingerprint)
    print(try keychainPath(store))
} catch {
    FileHandle.standardError.write(Data("Local signing failed: \(error.localizedDescription)\nSet MACDUO_SIGNING_IDENTITY to use an existing signing identity.\n".utf8))
    exit(1)
}
