import Foundation
import Security
import AppKit

// Soft-gate donation unlock. User donates via Stripe, confirmation page shows
// the unlock code. Entering it here removes ads and unlocks remote access.
// Code is stored in Keychain so it survives app reinstalls.

@MainActor
class PremiumManager: ObservableObject {
    // Update this when you want to rotate the code (old codes stop working).
    // Set this same value on the Stripe Payment Link confirmation page.
    private static let validCode = "SONIQUE-2025"
    private static let keychainKey = "com.seayniclabs.soniquebar.unlockcode"

    @Published private(set) var isPremium = false

    init() {
        isPremium = storedCode() == Self.validCode
    }

    // Returns true if the code is valid and saves it.
    @discardableResult
    func redeem(_ code: String) -> Bool {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard trimmed == Self.validCode else { return false }
        save(code: trimmed)
        isPremium = true
        return true
    }

    func openDonationPage() {
        if let url = URL(string: "https://buy.stripe.com/3cI5kFdtuaeh0Y6gfN8AE00") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Keychain

    private func storedCode() -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: Self.keychainKey,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func save(code: String) {
        guard let data = code.data(using: .utf8) else { return }
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: Self.keychainKey,
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }
}
