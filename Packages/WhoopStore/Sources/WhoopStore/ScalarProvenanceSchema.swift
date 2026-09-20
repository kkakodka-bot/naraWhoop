import GRDB

extension WhoopStore {
    /// Root registers this additive helper as v52. Existing rows remain NULL.
    public nonisolated static func installScalarProvenanceSchema(_ db: Database) throws {
        try db.execute(sql: """
            ALTER TABLE stepSample ADD COLUMN provenanceJSON TEXT;
            ALTER TABLE sleepStateSample ADD COLUMN provenanceJSON TEXT;
            ALTER TABLE ppgHrSample ADD COLUMN provenanceJSON TEXT;
            """)
    }
}
