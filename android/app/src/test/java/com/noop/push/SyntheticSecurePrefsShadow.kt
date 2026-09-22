package com.noop.push

import android.content.Context
import android.content.SharedPreferences
import com.noop.account.AccountStorageContext
import com.noop.data.SecurePrefs
import org.robolectric.annotation.Implementation
import org.robolectric.annotation.Implements

/** Synthetic credential storage for JVM acquisition tests; Android Keystore is a device-only gate. */
@Implements(value = SecurePrefs::class, isInAndroidSdk = false)
class SyntheticSecurePrefsShadow {
    @Implementation
    fun of(context: Context, fileName: String): SharedPreferences =
        AccountStorageContext.capture(context).getSharedPreferences("synthetic.$fileName", Context.MODE_PRIVATE)
}
