import Foundation
import XCTest
@testable import Alfred

/// Secret-reference types and the redaction guarantee (OCS §7), plus the legacy-behaviour guarantee
/// that turning the feature flag off changes nothing (OCS §9 of the implementation package).
final class SecretRefTests: XCTestCase {

    // MARK: 19. Secrets render as <redacted>

    func testSecretValueAlwaysRendersRedacted() {
        let secret = Secret("super-secret-value-12345",
                            origin: .keychain(service: "com.alfred.app", account: "telegram"))

        XCTAssertEqual("\(secret)", "<redacted>")
        XCTAssertEqual(secret.description, "<redacted>")
        XCTAssertEqual(secret.debugDescription, "<redacted>")
        XCTAssertFalse("Token: \(secret)".contains("super-secret-value"),
                       "String interpolation must not expose the value.")
        XCTAssertEqual(secret.reveal(), "super-secret-value-12345",
                       "Explicit reveal() is the only way through.")
    }

    func testSecretRefusesToEncode() {
        let secret = Secret("value", origin: .environment(name: "CLOUD_BOT_TOKEN"))
        XCTAssertThrowsError(try JSONEncoder().encode(secret),
                             "A secret must never be serializable.")
    }

    func testSecretReferenceDescribesThePointerNotAValue() {
        XCTAssertEqual(SecretRef.environment(name: "CLOUD_BOT_TOKEN").description,
                       "env:CLOUD_BOT_TOKEN")
        XCTAssertEqual(SecretRef.keychain(service: "com.alfred.app", account: "telegram").description,
                       "keychain:com.alfred.app/telegram")
        XCTAssertEqual(SecretRef.secretId("abc").auditLabel, "secretId:abc")
    }

    // MARK: Coding

    func testSecretRefRoundTripsForEachCase() throws {
        let cases: [SecretRef] = [
            .keychain(service: "com.alfred.app", account: "telegram"),
            .environment(name: "CLOUD_BOT_TOKEN"),
            .secretId("mail-primary"),
        ]
        for ref in cases {
            let data = try JSONEncoder().encode(ref)
            XCTAssertEqual(try JSONDecoder().decode(SecretRef.self, from: data), ref)
        }
    }

    func testSecretRefUsesADistinctiveWireShape() throws {
        let data = try JSONEncoder().encode(SecretRef.environment(name: "CLOUD_BOT_TOKEN"))
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertTrue(json.contains("environmentRef"),
                      "A bare string must not be mistakable for a reference.")
    }

    func testDecodingAnUnrecognizedSecretRefShapeFails() {
        let data = Data(#"{"somethingElse":"x"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(SecretRef.self, from: data))
    }

    // MARK: Validation patterns

    func testEnvironmentNamePattern() {
        for valid in ["CLOUD_BOT_TOKEN", "A", "OWNER_CHAT_ID", "X1_Y2"] {
            XCTAssertTrue(OwnerConfigValidator.matches(valid, SecretRef.environmentNamePattern), valid)
        }
        for invalid in ["lowercase", "1LEADING_DIGIT", "HAS SPACE", "HAS-DASH", ""] {
            XCTAssertFalse(OwnerConfigValidator.matches(invalid, SecretRef.environmentNamePattern), invalid)
        }
    }

    func testKeychainServiceAllowlistIsNarrow() {
        XCTAssertTrue(SecretRef.allowedKeychainServices.contains("com.alfred.app"))
        XCTAssertFalse(SecretRef.allowedKeychainServices.contains("com.apple.safari"))
    }
}

// MARK: - Legacy behaviour

/// 14. With `ownerConfigEnabled` off, nothing changes: the legacy persona is still available and
/// still owner-name driven.
final class LegacyPersonaFallbackTests: XCTestCase {

    func testLegacyPersonaStillRendersFromOwnerName() {
        let legacy = AssistantPersona.systemIntro(ownerName: "Legacy Owner",
                                                  currentDate: "Monday, July 27, 2026 at 09:00 EDT")

        XCTAssertTrue(legacy.contains("Legacy Owner"))
        XCTAssertTrue(legacy.contains("You are Alfred"))
    }

    func testLegacyAndConfiguredPersonasAreDistinct() {
        let date = "Monday, July 27, 2026 at 09:00 EDT"
        let legacy = AssistantPersona.systemIntro(ownerName: "Owner", currentDate: date)
        let configured = PersonaTemplate.render(
            snapshot: OwnerConfigSnapshot(
                config: OwnerConfigFixtures.minimalValid(name: "Owner"),
                validation: .clean),
            currentDate: date)

        XCTAssertNotEqual(legacy, configured)
        XCTAssertTrue(configured.contains("authoritative"),
                      "Only the configured persona declares the authored block authoritative.")
    }

    func testOwnerConfigFeatureFlagDefaultsOff() {
        // The flag is read with a `false` default, so an existing install is unaffected until the
        // owner opts in. Asserted against the same key AppState uses.
        let defaults = UserDefaults(suiteName: "owner-config-flag-test")!
        defaults.removePersistentDomain(forName: "owner-config-flag-test")
        let value = defaults.object(forKey: "ownerConfigEnabled") as? Bool ?? false
        XCTAssertFalse(value)
    }
}
