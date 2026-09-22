package android.content

/**
 * Minimal compile-time stub of the Android `SharedPreferences` interface pair.
 *
 * Why this exists: exactly ONE function in the synced kernel —
 * `Baselines.recalibrateRecoveryBaselines(editor: android.content.SharedPreferences.Editor, …)` —
 * names this type (the device-side "Recalibrate baselines" settings helper). The scoring service
 * never calls it, but the byte-verbatim sync of `Baselines.kt` must compile, and the synced
 * `HrvBaselineRecalibrationTest` implements a fake `Editor` against it. On Android the type comes
 * from the SDK's android.jar; a bare JDK has nothing.
 *
 * This is deliberately the ENTIRE android.* surface of the kernel — 2 interfaces, 10 methods, no
 * behavior. It is NOT a license to add more android stubs: any new android.* reference in the
 * synced tree fails `verifyKernelScope`, and any new stub file here is a scope decision that must
 * be justified in the module's build file.
 */
interface SharedPreferences {
    interface Editor {
        fun putString(key: String?, value: String?): Editor
        fun putStringSet(key: String?, values: MutableSet<String>?): Editor
        fun putInt(key: String?, value: Int): Editor
        fun putLong(key: String, value: Long): Editor
        fun putFloat(key: String?, value: Float): Editor
        fun putBoolean(key: String?, value: Boolean): Editor
        fun remove(key: String?): Editor
        fun clear(): Editor
        fun commit(): Boolean
        fun apply()
    }
}
