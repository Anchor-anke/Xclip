import Foundation

// Tests the production AuthenticationGate without constructing PrivacyLock.shared,
// reading Keychain, showing authentication prompts, or changing system state.
// Extract the PrivacyLock class verbatim from WorkflowState.swift (up to the next
// "/// Typed local URL" comment) with its Foundation/Combine/LocalAuthentication/
// Security/CryptoKit imports, then compile that file and this file with:
// xcrun swiftc -swift-version 5 -D PRIVACY_LOCK_STANDALONE_TESTS -parse-as-library /private/tmp/oneclip-privacy-class.swift tests/PrivacyLockTests.swift -o /private/tmp/oneclip-privacy-tests
#if PRIVACY_LOCK_STANDALONE_TESTS
func L(_ chinese: String, _ english: String) -> String { chinese }
enum ClipboardError: Error { case dataCorrupted }
#endif

@main
struct PrivacyLockTests {
    static func main() {
        var checks = 0
        func require(_ condition: Bool, _ description: String) {
            precondition(condition, description)
            checks += 1
        }
        var gate = PrivacyLock.AuthenticationGate()
        require(gate.activeAttempt == nil, "No authentication is active initially")

        let initial = gate.begin()
        require(gate.activeAttempt == initial, "Starting authentication marks its current attempt")
        require(gate.finish(initial), "A current callback is accepted")
        require(!gate.finish(initial), "A duplicate callback cannot be replayed")

        let beforeSleep = gate.begin()
        gate.invalidate()
        require(gate.activeAttempt == nil, "Lock invalidates the active attempt")
        require(!gate.finish(beforeSleep), "A password or biometric success arriving after lock is rejected")

        let current = gate.begin()
        require(current != beforeSleep, "Authentication started after lock uses a different identity")
        require(!gate.finish(beforeSleep), "An old failure cannot consume a new authentication attempt")
        require(gate.activeAttempt == current, "The new attempt survives an obsolete completion")
        require(gate.finish(current), "The new authentication attempt can complete normally")

        let superseded = gate.begin()
        let replacement = gate.begin()
        require(!gate.finish(superseded), "Replacing an attempt rejects its old callback")
        require(gate.finish(replacement), "A replacement callback remains valid")

        let multipleLocks = gate.begin()
        gate.invalidate()
        gate.invalidate()
        require(!gate.finish(multipleLocks), "Repeated lock notifications keep old callbacks invalid")
        let afterLocks = gate.begin()
        require(gate.finish(afterLocks), "Authentication still works after repeated lock notifications")
        print("Privacy authentication tests passed: \(checks) checks. No Keychain access or system authentication invoked.")
    }
}
