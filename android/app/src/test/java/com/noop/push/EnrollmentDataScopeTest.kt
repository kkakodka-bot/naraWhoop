package com.noop.push

import java.nio.file.Files
import org.junit.Assert.*
import org.junit.Test

class EnrollmentDataScopeTest {
    @Test fun missingOrMismatchedDeviceWitnessRotatesSourceWithoutReusingOldStore() {
        val directory = Files.createTempDirectory("enrollment-source-test").toFile()
        try {
            val prefs = SelfHostedPushSettingsTest.FakePushPrefs()
            val first = EnrollmentDataScope.installationSource(directory, prefs)
            assertEquals(first, EnrollmentDataScope.installationSource(directory, prefs))
            directory.resolve("noop-installation-source").delete()
            val second = EnrollmentDataScope.installationSource(directory, prefs)
            assertNotEquals(first, second)
            prefs.edit().putString("source_id", first).commit()
            val third = EnrollmentDataScope.installationSource(directory, prefs)
            assertNotEquals(first, third); assertNotEquals(second, third)
            val owner = "11111111-1111-1111-1111-111111111111"
            assertNotEquals(EnrollmentDataScope.Scope(owner, first).databaseName, EnrollmentDataScope.Scope(owner, third).databaseName)
        } finally { directory.deleteRecursively() }
    }

    @Test fun ownerAndInstallationScopesNeverSelectLegacyDatabase() {
        val a = EnrollmentDataScope.Scope("owner-a", "source-a")
        assertNotEquals("noop_whoop.db", a.databaseName)
        assertNotEquals(a.databaseName, EnrollmentDataScope.Scope("owner-b", "source-a").databaseName)
        assertNotEquals(a.databaseName, EnrollmentDataScope.Scope("owner-a", "source-b").databaseName)
        assertEquals(a, EnrollmentDataScope.Scope("owner-a", "source-a"))
    }
}
