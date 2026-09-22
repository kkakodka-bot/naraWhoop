package com.noop.push

import android.app.Application
import android.content.ContextWrapper
import android.content.SharedPreferences
import com.noop.account.AccountStorageContext
import com.noop.account.AccountStorageMutationLease
import com.noop.ui.ProfileStore
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = Application::class)
class AccountProfileMutationFenceTest {
    private fun prefs(account: AccountStorageContext) = account.getSharedPreferences("noop_profile", 0)

    private fun everyMutation(profile: ProfileStore) {
        profile.dateOfBirthMillis = ProfileStore.dobForAge(42)
        profile.setAge(43)
        profile.sex = "female"
        profile.weightKg = 82.0
        profile.heightCm = 169.0
        profile.waistCm = 81.0
        profile.hrMaxOverride = 181
        profile.stepTicksPerStep = 2.0
        profile.stepsCalibrationCoefficient = 1.5
        profile.stepsCalibrationSampleDays = 7
        profile.stepsCalibrationConfidence = 0.75
        profile.stepsCalibrationManual = true
        profile.stepsManualCoefficient = 2.5
        profile.stepsHasBankedMotion = true
        profile.hrZoneThresholds = listOf(80, 100, 120, 140, 160)
        profile.stepHrZoneThreshold(1, true)
        profile.setCustomHrZonesEnabled(false)
        profile.setCustomHrZonesEnabled(true)
        profile.applyBackup(mapOf("profile.weightKg" to 83.0, "profile.age" to 44,
            "profile.hrZoneThresholds" to "81,101,121,141,161"))
    }

    @Test fun currentProfileKeepsDefaultsClampsExplicitFieldsAndCallbacks() {
        StorageMutationFixture().use { f ->
            val account = f.account(); val backing = prefs(account)
            val lease = AccountStorageMutationLease.capture(account)
            val callbacks = mutableListOf<Boolean>()
            val profile = ProfileStore(backing, onScoringChange = { saved, configuration ->
                assertFalse(backing.getStringSet("server_explicit_fields", emptySet()).isNullOrEmpty())
                assertNotNull(saved.scoringProfile("UTC")); callbacks += configuration
            }, canWrite = { lease.admitsWrites() }, commitMutation = { lease.commit(it) })
            assertEquals(75.0, profile.weightKg, 0.0)
            assertEquals(178.0, profile.heightCm, 0.0)
            assertEquals(30, profile.age)
            assertNull(profile.scoringProfile("UTC").age)
            everyMutation(profile)
            assertEquals(83.0, profile.weightKg, 0.0)
            assertEquals(44, profile.age)
            assertEquals(1.5, profile.stepsCalibrationCoefficient, 0.0)
            assertEquals(7, profile.stepsCalibrationSampleDays)
            assertEquals(0.75, profile.stepsCalibrationConfidence, 0.0)
            assertTrue(profile.stepsCalibrationManual); assertTrue(profile.stepsHasBankedMotion)
            assertEquals(2.5, profile.stepsManualCoefficient, 0.0)
            assertEquals(listOf(81, 101, 121, 141, 161), profile.hrZoneThresholds)
            assertEquals(setOf("age", "sex", "weight", "height", "waist", "maxHR", "steps"),
                backing.getStringSet("server_explicit_fields", emptySet()))
            assertEquals(10, callbacks.size); assertEquals(1, callbacks.count { it })
            profile.weightKg = -100.0
            assertEquals(30.0, profile.weightKg, 0.0)
            assertEquals(profile.backupSnapshot(), ProfileStore.from(account).backupSnapshot())
        }
    }

    @Test fun everyOldAMutationIsRejectedAfterBReplacement() = replacementRejectsMutations("b")
    @Test fun everyOldAMutationIsRejectedAfterNewAGeneration() = replacementRejectsMutations("a")

    private fun replacementRejectsMutations(next: String) {
        StorageMutationFixture().use { f ->
            val old = f.account(); val profile = ProfileStore.from(old)
            profile.weightKg = 70.0; profile.hrZoneThresholds = listOf(80, 100, 120, 140, 160)
            val before = prefs(old).all.toMap()
            f.login(next)
            val current = f.account()
            val nextBefore = prefs(current).all.toMap()
            everyMutation(profile)
            assertEquals(before, prefs(old).all)
            assertEquals(nextBefore, prefs(current).all)
            ProfileStore.from(current).weightKg = 90.0
            everyMutation(profile)
            assertEquals(90.0, ProfileStore.from(current).weightKg, 0.0)
        }
    }

    @Test fun databaseRetirementRejectsEverySetterAndFreshFacadeInTheSameIdentity() {
        StorageMutationFixture().use { f ->
            val account = f.account(); val room = f.room(account)
            val profile = ProfileStore.from(account)
            profile.weightKg = 70.0
            val before = prefs(account).all.toMap()
            room.retireWrites()
            everyMutation(profile)
            everyMutation(ProfileStore.from(account))
            assertEquals(before, prefs(account).all)
        }
    }

    @Test fun retiredLazyDobMigrationDoesNotPersistADefault() {
        StorageMutationFixture().use { f ->
            val account = f.account(); val room = f.room(account); val profile = ProfileStore.from(account)
            room.retireWrites()
            assertEquals(30, profile.age)
            assertTrue(prefs(account).all.isEmpty())
        }
    }

    private fun interceptedAccount(
        f: StorageMutationFixture,
        onEdit: () -> Unit = {},
        beforeCommit: () -> Unit = {},
    ): AccountStorageContext = f.account(object : ContextWrapper(f.app) {
        override fun getSharedPreferences(name: String, mode: Int): SharedPreferences {
            val backing = super.getSharedPreferences(name, mode)
            return object : SharedPreferences by backing {
                override fun edit(): SharedPreferences.Editor {
                    val editor = backing.edit()
                    onEdit()
                    return object : SharedPreferences.Editor by editor {
                        override fun commit(): Boolean { beforeCommit(); return editor.commit() }
                    }
                }
            }
        }
    })

    @Test fun reentrantRetirementDuringEditorPreparationCannotCommit() {
        StorageMutationFixture().use { f ->
            val ordinary = f.account(); val room = f.room(ordinary)
            val account = interceptedAccount(f, onEdit = { room.retireWrites() })
            ProfileStore.from(account).weightKg = 84.0
            assertTrue(prefs(ordinary).all.isEmpty())
        }
    }

    @Test fun reentrantLogoutDuringEditorPreparationCannotCommit() {
        StorageMutationFixture().use { f ->
            val ordinary = f.account()
            val account = interceptedAccount(f, onEdit = { f.controller.clearSession() })
            ProfileStore.from(account).stepsCalibrationCoefficient = 8.0
            assertTrue(prefs(ordinary).all.isEmpty())
        }
    }

    @Test fun admittedPreferenceCommitLinearizesBeforeAuthReplacement() = admittedCommit(false)
    @Test fun admittedPreferenceCommitLinearizesBeforeExplicitRuntimeRetirement() = admittedCommit(true)

    private fun admittedCommit(explicitRetirement: Boolean) {
        StorageMutationFixture().use { f ->
            val ordinary = f.account(); val room = f.room(ordinary)
            val atCommit = CountDownLatch(1); val release = CountDownLatch(1)
            val attempted = CountDownLatch(1); val retired = CountDownLatch(1)
            val armed = AtomicBoolean(true)
            val account = interceptedAccount(f, beforeCommit = {
                if (armed.compareAndSet(true, false)) {
                    atCommit.countDown(); check(release.await(10, TimeUnit.SECONDS))
                }
            })
            val profile = ProfileStore.from(account)
            val executor = Executors.newFixedThreadPool(2)
            try {
                val write = executor.submit { profile.stepsCalibrationCoefficient = 1.75 }
                assertTrue(atCommit.await(10, TimeUnit.SECONDS))
                val retirement = executor.submit {
                    attempted.countDown()
                    if (explicitRetirement) room.retireWrites() else f.login("b")
                    retired.countDown()
                }
                assertTrue(attempted.await(10, TimeUnit.SECONDS))
                assertFalse(retired.await(150, TimeUnit.MILLISECONDS))
                release.countDown(); write.get(10, TimeUnit.SECONDS); retirement.get(10, TimeUnit.SECONDS)
                assertEquals(1.75, ProfileStore.from(ordinary).stepsCalibrationCoefficient, 0.0)
                val before = prefs(ordinary).all.toMap()
                everyMutation(profile)
                assertEquals(before, prefs(ordinary).all)
            } finally { release.countDown(); executor.shutdownNow(); assertTrue(executor.awaitTermination(10, TimeUnit.SECONDS)) }
        }
    }
}
