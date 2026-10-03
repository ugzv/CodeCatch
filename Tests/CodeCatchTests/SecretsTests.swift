import Foundation
import Security
import Testing
@testable import CodeCatch

private func expectAccountScope(_ dictionary: CFDictionary, account: String) {
    let attributes = dictionary as NSDictionary
    #expect(attributes[kSecClass as String] as? String == kSecClassGenericPassword as String)
    #expect(attributes[kSecAttrService as String] as? String == "com.uros.codecatch")
    #expect(attributes[kSecAttrAccount as String] as? String == account)
}

private func expectFailure(_ status: OSStatus, performing operation: () throws -> Void) {
    do {
        try operation()
        Issue.record("Expected a Keychain failure")
    } catch let failure as Secrets.Failure {
        #expect(failure.status == status)
    } catch {
        Issue.record("Unexpected error type: \(type(of: error))")
    }
}

@Test func updatingExistingSecretPreservesScopeAndNeverAdds() throws {
    let account = "existing:ü@example.com"
    let value = "pässw🔐rd\n"
    var updateCalls = 0
    var addCalls = 0

    try Secrets.set(value, for: account, update: { query, changes in
        updateCalls += 1
        expectAccountScope(query, account: account)
        #expect((changes as NSDictionary)[kSecValueData as String] as? Data == Data(value.utf8))
        return errSecSuccess
    }, add: { _, _ in
        addCalls += 1
        return errSecSuccess
    })

    #expect(updateCalls == 1)
    #expect(addCalls == 0)
}

@Test func missingSecretIsAddedOnceAfterUpdateWithExactScopeAndUTF8Value() throws {
    let account = "missing:ü@example.com"
    let value = "pässw🔐rd\n"
    var updateCalls = 0
    var addCalls = 0

    try Secrets.set(value, for: account, update: { query, _ in
        updateCalls += 1
        expectAccountScope(query, account: account)
        return errSecItemNotFound
    }, add: { attributes, _ in
        addCalls += 1
        #expect(updateCalls == 1)
        expectAccountScope(attributes, account: account)
        #expect((attributes as NSDictionary)[kSecValueData as String] as? Data == Data(value.utf8))
        return errSecSuccess
    })

    #expect(updateCalls == 1)
    #expect(addCalls == 1)
}

@Test(arguments: [errSecAuthFailed, errSecInteractionNotAllowed, errSecUserCanceled, OSStatus(-12345)])
func failedUpdatePreservesStatusWithoutAttemptingAdd(status: OSStatus) {
    var updateCalls = 0
    var addCalls = 0

    expectFailure(status) {
        try Secrets.set("value", for: "account", update: { _, _ in
            updateCalls += 1
            return status
        }, add: { _, _ in
            addCalls += 1
            return errSecSuccess
        })
    }

    #expect(updateCalls == 1)
    #expect(addCalls == 0)
}

@Test(arguments: [errSecDuplicateItem, errSecAuthFailed, errSecInteractionNotAllowed, OSStatus(-12345)])
func failedAddPreservesStatusWithoutRetrying(status: OSStatus) {
    var updateCalls = 0
    var addCalls = 0

    expectFailure(status) {
        try Secrets.set("value", for: "account", update: { _, _ in
            updateCalls += 1
            return errSecItemNotFound
        }, add: { _, _ in
            addCalls += 1
            #expect(updateCalls == 1)
            return status
        })
    }

    #expect(updateCalls == 1)
    #expect(addCalls == 1)
}
