import GRDB
@testable import WhoopStore

/// Synthetic remote-durability fixture for retention-policy tests only. Each newly captured
/// resource has an independently verified remote twin with the same owner/key/checksum and
/// expired grace. The trigger supplies receipts before the production amortised sweep runs.
/// Tests without this explicit fixture exercise the default no-receipt preservation policy.
func installVerifiedRawReceiptFixture(_ store: WhoopStore) async throws {
    try await store.bindAccountOwner(projectURL: "https://retention-fixture.invalid",
                                    userID: "22222222-2222-4222-8222-222222222222")
    try await store.registryWriter.write { db in
        try db.execute(sql: """
            CREATE TRIGGER fixture_verified_remote_twin AFTER INSERT ON ingestRawResource
            WHEN NEW.environment IS NOT NULL AND NEW.accountId IS NOT NULL
            BEGIN
                INSERT INTO rawDurabilityReceipt
                    (lane, deviceId, resourceKey, scopeKey, contentSHA256, objectKey, receiptId, verifiedAt, retainUntil)
                VALUES (NEW.lane, NEW.deviceId, NEW.resourceKey, NEW.scopeKey, NEW.contentSHA256,
                        'fixture/verified-object', 'fixture/verified-manifest', 1, 1);
            END
            """)
    }
}

func receiptedFixtureStore() async throws -> WhoopStore {
    let store = try await WhoopStore.inMemory()
    try await installVerifiedRawReceiptFixture(store)
    return store
}
