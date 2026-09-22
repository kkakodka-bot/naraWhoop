package com.noop.testing

import android.content.Context
import android.content.SharedPreferences
import com.noop.account.AccountStorageContext
import com.noop.data.SecurePrefs
import org.robolectric.annotation.Implementation
import org.robolectric.annotation.Implements
import org.robolectric.internal.ShadowProvider

/** JVM boundary double only: macOS has no AndroidKeyStore. Account namespacing remains production code.
 * This does NOT validate encryption; that remains an instrumented-device/provider gate. */
@Implements(value = SecurePrefs::class, isInAndroidSdk = false)
class ShadowSecurePrefs {
    @Implementation
    fun of(context: Context, fileName: String): SharedPreferences =
        AccountStorageContext.capture(context).getSharedPreferences("jvm-secure-boundary.$fileName", Context.MODE_PRIVATE)
}

class SecurePrefsShadowProvider : ShadowProvider {
    override fun reset() = Unit
    override fun getProvidedPackageNames(): Array<String> = arrayOf("com.noop.data.SecurePrefs")
    override fun getShadows(): Collection<Map.Entry<String, String>> =
        mapOf("com.noop.data.SecurePrefs" to "com.noop.testing.ShadowSecurePrefs").entries
}
