import Contacts
import Foundation

struct PhoneContact: Identifiable, Sendable {
    let id: String
    let name: String
    let number: String
    let dialInitials: String
    let dialFullName: String

    var dialableNumber: String {
        let digits = number.filter(\.isNumber)
        return number.trimmingCharacters(in: .whitespaces).hasPrefix("+") ? "+" + digits : digits
    }

    func matchesDialDigits(_ input: String) -> Bool {
        guard !input.isEmpty, input.allSatisfy(\.isNumber) else { return false }
        return dialInitials.hasPrefix(input) || dialFullName.hasPrefix(input)
    }

    static func keypadDigits(_ letters: String) -> String {
        let groups = ["abc", "def", "ghi", "jkl", "mno", "pqrs", "tuv", "wxyz"]
        return String(letters.lowercased().compactMap { character -> Character? in
            guard let index = groups.firstIndex(where: { $0.contains(character) }) else { return nil }
            return Character(String(index + 2))
        })
    }
}

enum PhoneContactsError: LocalizedError {
    case denied
    var errorDescription: String? { "未获得通讯录权限。可在 iPhone 设置中允许「随行号」访问通讯录。" }
}

enum PhoneContacts {
    static var permissionDescription: String {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized: return "已授权"
        case .limited: return "部分联系人"
        case .denied, .restricted: return "未授权"
        default: return "未请求"
        }
    }

    static var canRead: Bool {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        return status == .authorized || status == .limited
    }

    private static func comparableDigits(_ raw: String) -> String {
        var digits = raw.filter(\.isNumber)
        if digits.hasPrefix("0086") { digits = String(digits.dropFirst(4)) }
        else if digits.hasPrefix("86") && digits.count >= 12 { digits = String(digits.dropFirst(2)) }
        if digits.count >= 9 && digits.count <= 12 && !digits.hasPrefix("0") && !digits.hasPrefix("1") && !digits.hasPrefix("400") && !digits.hasPrefix("800") {
            digits = "0" + digits
        }
        return digits
    }

    static func name(matching number: String) async -> String? {
        let permission = CNContactStore.authorizationStatus(for: .contacts)
        guard permission == .authorized || permission == .limited else { return nil }
        let target = comparableDigits(number)
        guard !target.isEmpty else { return nil }
        return await Task.detached(priority: .userInitiated) {
            let store = CNContactStore()
            let request = CNContactFetchRequest(keysToFetch: [CNContactGivenNameKey as CNKeyDescriptor,
                                                               CNContactFamilyNameKey as CNKeyDescriptor,
                                                               CNContactPhoneNumbersKey as CNKeyDescriptor])
            var found: String?
            try? store.enumerateContacts(with: request) { contact, stop in
                if contact.phoneNumbers.contains(where: { comparableDigits($0.value.stringValue) == target }) {
                    let name = [contact.familyName, contact.givenName]
                        .joined().trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty { found = name; stop.pointee = true }
                }
            }
            return found
        }.value
    }

    static func load() async throws -> [PhoneContact] {
        let store = CNContactStore()
        if CNContactStore.authorizationStatus(for: .contacts) == .notDetermined {
            _ = try await store.requestAccess(for: .contacts)
        }
        let authorization = CNContactStore.authorizationStatus(for: .contacts)
        guard authorization == .authorized || authorization == .limited else { throw PhoneContactsError.denied }
        return try await Task.detached(priority: .userInitiated) {
            let request = CNContactFetchRequest(keysToFetch: [CNContactGivenNameKey as CNKeyDescriptor,
                                                               CNContactFamilyNameKey as CNKeyDescriptor,
                                                               CNContactPhoneNumbersKey as CNKeyDescriptor])
            var result: [PhoneContact] = []
            try store.enumerateContacts(with: request) { contact, _ in
                let name = [contact.familyName, contact.givenName].joined()
                let display = name.isEmpty ? "未命名联系人" : name
                let latin = name.applyingTransform(.toLatin, reverse: false)?
                    .applyingTransform(.stripCombiningMarks, reverse: false)?
                    .lowercased() ?? ""
                let syllables = latin.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                let initials = String(syllables.compactMap(\.first))
                let dialInitials = PhoneContact.keypadDigits(initials)
                let dialFullName = PhoneContact.keypadDigits(latin)
                for (index, item) in contact.phoneNumbers.enumerated() {
                    let number = item.value.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !number.isEmpty else { continue }
                    result.append(PhoneContact(id: "\(contact.identifier)-\(index)", name: display,
                                               number: number, dialInitials: dialInitials,
                                               dialFullName: dialFullName))
                }
            }
            return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }.value
    }
}
