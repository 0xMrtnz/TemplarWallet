import Cocoa
import CryptoKit
import FlutterMacOS
import LocalAuthentication

/// Touch ID unlock of the vault on macOS: the vault key sealed to a Secure
/// Enclave key whose use requires the current biometric set.
///
/// Why not the keychain: every Templar build outside the App Store is ad-hoc
/// signed, so it carries no application-identifier entitlement, and without
/// one the data-protection keychain refuses every SecAccessControl item
/// (errSecMissingEntitlement, -34018). CryptoKit's Secure Enclave keys never
/// touch the keychain — the private key lives in the enclave, its opaque
/// `dataRepresentation` is a file of ours, and the access control on it
/// (`.biometryCurrentSet | .privateKeyUsage`) is enforced by the enclave.
/// Re-enrolling a fingerprint invalidates the key, exactly as the Android
/// Keystore does; the sealed file then reads as gone and the feature switches
/// itself off on the Dart side.
///
/// Sealing is ECIES: an ephemeral P-256 key agrees with the enclave key's
/// public half (no prompt), HKDF-SHA256 derives an AES-GCM key, and the file
/// keeps blob + ephemeral public key + ciphertext. Reading agrees the enclave
/// key with the ephemeral public key — the operation gated by Touch ID. The
/// prompt is shown by an explicit `evaluatePolicy` first, so the user sees
/// Templar's own reason and cancel title, and the same authenticated context
/// then satisfies the key's access control without a second prompt.
///
/// Method channel `dev.templarwallet/touch_id`:
///   availability()            -> "available" | "noneEnrolled" | "unavailable"
///   write(content, reason)    -> nil; prompts once to prove the round trip
///   read(reason)              -> String? (nil when nothing is sealed)
///   delete()                  -> nil
/// Errors: FlutterError code "cancelled" | "lockout" | "not_enrolled" |
/// "invalidated" | "failed", message = the system's own wording.
final class TouchIdVaultKey: NSObject {
  static let channelName = "dev.templarwallet/touch_id"

  private static let salt = "templar-touch-id-v1".data(using: .utf8)!
  private static let fileVersion = 1

  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    let instance = TouchIdVaultKey()
    channel.setMethodCallHandler { call, result in instance.handle(call, result: result) }
  }

  // MARK: - Channel

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    let reason = args["reason"] as? String ?? "Unlock wallet storage"
    switch call.method {
    case "availability":
      result(availability())
    case "write":
      guard let content = args["content"] as? String, !content.isEmpty else {
        result(FlutterError(code: "failed", message: "Nothing to seal", details: nil))
        return
      }
      // Off the main thread: the Touch ID sheet blocks the caller until the
      // user answers, and the Flutter UI must keep painting under it.
      DispatchQueue.global(qos: .userInitiated).async {
        let outcome = self.write(content, reason: reason)
        DispatchQueue.main.async { self.deliver(outcome, result) }
      }
    case "read":
      DispatchQueue.global(qos: .userInitiated).async {
        let outcome = self.read(reason: reason)
        DispatchQueue.main.async { self.deliver(outcome, result) }
      }
    case "delete":
      deliver(delete(), result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  fileprivate enum Outcome: Error {
    case value(String?)
    case failure(code: String, message: String)

    var codeIsCancel: Bool {
      if case .failure(let code, _) = self { return code == "cancelled" }
      return false
    }

    var messageText: String {
      if case .failure(_, let message) = self { return message }
      return ""
    }
  }

  private func deliver(_ outcome: Outcome, _ result: FlutterResult) {
    switch outcome {
    case .value(let v): result(v)
    case .failure(let code, let message):
      result(FlutterError(code: code, message: message, details: nil))
    }
  }

  // MARK: - Availability

  private func availability() -> String {
    guard SecureEnclave.isAvailable else { return "unavailable" }
    var error: NSError?
    let context = LAContext()
    if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) {
      return context.biometryType == .touchID ? "available" : "unavailable"
    }
    if let error, LAError.Code(rawValue: error.code) == .biometryNotEnrolled {
      return "noneEnrolled"
    }
    return "unavailable"
  }

  // MARK: - Storage

  private struct Sealed: Codable {
    let v: Int
    let key: Data   // Secure Enclave key blob (dataRepresentation)
    let eph: Data   // ephemeral P-256 public key, raw
    let box: Data   // AES-GCM combined (nonce + ciphertext + tag)
  }

  private var fileURL: URL? {
    guard let support = FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask).first
    else { return nil }
    return support
      .appendingPathComponent("TemplarWallet", isDirectory: true)
      .appendingPathComponent("touch_id_vault_key.json")
  }

  private func accessControl() -> SecAccessControl? {
    var error: Unmanaged<CFError>?
    return SecAccessControlCreateWithFlags(
      nil,
      kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
      [.privateKeyUsage, .biometryCurrentSet],
      &error)
  }

  private func symmetricKey(from secret: SharedSecret, ephemeralPublic: Data) -> SymmetricKey {
    secret.hkdfDerivedSymmetricKey(
      using: SHA256.self,
      salt: Self.salt,
      sharedInfo: ephemeralPublic,
      outputByteCount: 32)
  }

  /// The Touch ID sheet, with Templar's reason and "Use passphrase" as the
  /// way out. Returns the authenticated context to hand to the enclave key.
  private func authenticate(reason: String) -> Result<LAContext, Outcome> {
    let context = LAContext()
    context.localizedCancelTitle = "Use passphrase"
    var authError: Error?
    let done = DispatchSemaphore(value: 0)
    context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { ok, error in
      if !ok { authError = error ?? LAError(.authenticationFailed) }
      done.signal()
    }
    done.wait()
    if let authError {
      return Result<LAContext, Outcome>.failure(Self.map(authError))
    }
    return Result<LAContext, Outcome>.success(context)
  }

  private func write(_ content: String, reason: String) -> Outcome {
    guard let url = fileURL else {
      return .failure(code: "failed", message: "No Application Support directory")
    }
    guard let acl = accessControl() else {
      return .failure(code: "failed", message: "Could not build the key's access control")
    }
    do {
      let enclaveKey = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: acl)
      let ephemeral = P256.KeyAgreement.PrivateKey()
      let secret = try ephemeral.sharedSecretFromKeyAgreement(with: enclaveKey.publicKey)
      let ephPub = ephemeral.publicKey.rawRepresentation
      let sym = symmetricKey(from: secret, ephemeralPublic: ephPub)
      guard let plain = content.data(using: .utf8) else {
        return .failure(code: "failed", message: "Content is not UTF-8")
      }
      let box = try AES.GCM.seal(plain, using: sym)
      guard let combined = box.combined else {
        return .failure(code: "failed", message: "AES-GCM produced no combined box")
      }
      let sealed = Sealed(v: Self.fileVersion, key: enclaveKey.dataRepresentation, eph: ephPub, box: combined)
      let json = try JSONEncoder().encode(sealed)

      // Prove the round trip before persisting anything: the prompt here is
      // the one the user sees when turning the feature on, and a key that
      // cannot be used is not worth a file.
      switch authenticate(reason: reason) {
      case .failure(let outcome): return outcome
      case .success(let context):
        let restored = try SecureEnclave.P256.KeyAgreement.PrivateKey(
          dataRepresentation: enclaveKey.dataRepresentation, authenticationContext: context)
        let ephPubKey = try P256.KeyAgreement.PublicKey(rawRepresentation: ephPub)
        let secret2 = try restored.sharedSecretFromKeyAgreement(with: ephPubKey)
        let opened = try AES.GCM.open(box, using: symmetricKey(from: secret2, ephemeralPublic: ephPub))
        guard opened == plain else {
          return .failure(code: "failed", message: "The sealed key did not read back")
        }
      }

      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try json.write(to: url, options: [.atomic])
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
      return .value(nil)
    } catch {
      return Self.map(error)
    }
  }

  private func read(reason: String) -> Outcome {
    guard let url = fileURL, FileManager.default.fileExists(atPath: url.path) else {
      return .value(nil)
    }
    let sealed: Sealed
    do {
      sealed = try JSONDecoder().decode(Sealed.self, from: Data(contentsOf: url))
    } catch {
      // Not ours, or half-written: treat as absent so the feature resets.
      return .value(nil)
    }
    guard sealed.v == Self.fileVersion else { return .value(nil) }

    switch authenticate(reason: reason) {
    case .failure(let outcome): return outcome
    case .success(let context):
      do {
        let enclaveKey = try SecureEnclave.P256.KeyAgreement.PrivateKey(
          dataRepresentation: sealed.key, authenticationContext: context)
        let ephPubKey = try P256.KeyAgreement.PublicKey(rawRepresentation: sealed.eph)
        let secret = try enclaveKey.sharedSecretFromKeyAgreement(with: ephPubKey)
        let box = try AES.GCM.SealedBox(combined: sealed.box)
        let plain = try AES.GCM.open(box, using: symmetricKey(from: secret, ephemeralPublic: sealed.eph))
        guard let text = String(data: plain, encoding: .utf8) else {
          return .failure(code: "invalidated", message: "The sealed key is unreadable")
        }
        return .value(text)
      } catch {
        // The user is authenticated, so a failing key operation means the
        // enclave key no longer works — a new fingerprint was enrolled — or
        // the file was damaged. Either way the file is dead.
        let mapped = Self.map(error)
        if mapped.codeIsCancel { return mapped }
        return .failure(code: "invalidated", message: mapped.messageText)
      }
    }
  }

  private func delete() -> Outcome {
    guard let url = fileURL else { return .value(nil) }
    do {
      if FileManager.default.fileExists(atPath: url.path) {
        try FileManager.default.removeItem(at: url)
      }
      return .value(nil)
    } catch {
      return .failure(code: "failed", message: error.localizedDescription)
    }
  }

  // MARK: - Errors

  private static func map(_ error: Error) -> Outcome {
    let ns = error as NSError
    if ns.domain == LAErrorDomain, let code = LAError.Code(rawValue: ns.code) {
      switch code {
      case .userCancel, .systemCancel, .appCancel, .userFallback:
        return .failure(code: "cancelled", message: ns.localizedDescription)
      case .biometryLockout:
        return .failure(code: "lockout", message: ns.localizedDescription)
      case .biometryNotEnrolled:
        return .failure(code: "not_enrolled", message: ns.localizedDescription)
      case .biometryNotAvailable, .passcodeNotSet:
        return .failure(code: "failed", message: ns.localizedDescription)
      default:
        return .failure(code: "failed", message: ns.localizedDescription)
      }
    }
    // Security-framework OSStatus surfaced through CryptoKit.
    if ns.code == Int(errSecUserCanceled) {
      return .failure(code: "cancelled", message: ns.localizedDescription)
    }
    return .failure(code: "failed", message: ns.localizedDescription)
  }
}
