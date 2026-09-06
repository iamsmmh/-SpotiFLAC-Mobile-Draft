package com.zarz.spotiflac

import android.content.Context
import android.util.Log
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKeys

/**
 * Production EncryptedSharedPreferences store. Mirrors [SecureStore] /
 * [SecureStorePolicy] in Dart so a Keystore master-key warmup on cold start
 * cannot drift from the Flutter facade.
 *
 * Uses security-crypto 1.0.0 [MasterKeys.getOrCreate] (not the 1.1-alpha
 * `MasterKey` builder) so minify + Play-signed builds stay on a stable API.
 */
internal object NativeSecureStorePolicy {
    const val PREFS_NAME = "spotiflac_secure_store"
    const val SCHEMA_VERSION_KEY = "spotiflac.secure.schema_version"
    const val CURRENT_SCHEMA_VERSION = 1
    const val SPOTIFY_CLIENT_SECRET = "spotify_client_secret"
    const val TOKEN_PREFIX = "spotiflac.token."
    const val SECRET_PREFIX = "spotiflac.secret."
    const val SIGNATURE_PREFIX = "spotiflac.extsig."
    const val MAX_KEY_LENGTH = 128
    const val MAX_VALUE_BYTES = 16 * 1024

    val retiredKeys: Set<String> = setOf(SPOTIFY_CLIENT_SECRET)

    fun isAllowedKey(key: String): Boolean {
        // Check the raw key for control characters BEFORE trimming, so a
        // trailing "\n" cannot be silently stripped into a valid key.
        if (key.contains('\n') || key.contains('\u0000')) return false
        val trimmed = key.trim()
        if (trimmed.isEmpty() || trimmed.length > MAX_KEY_LENGTH) return false
        if (trimmed == SCHEMA_VERSION_KEY) return true
        if (retiredKeys.contains(trimmed)) return true
        return (trimmed.startsWith(TOKEN_PREFIX) && trimmed.length > TOKEN_PREFIX.length) ||
            (trimmed.startsWith(SECRET_PREFIX) && trimmed.length > SECRET_PREFIX.length) ||
            (trimmed.startsWith(SIGNATURE_PREFIX) && trimmed.length > SIGNATURE_PREFIX.length)
    }

    fun isAllowedValue(value: String): Boolean = value.length <= MAX_VALUE_BYTES
}

internal object NativeSecureStore {
    private const val TAG = "NativeSecureStore"

    /**
     * Creates (or reuses) the AndroidX master key and EncryptedSharedPreferences
     * file, writes schema v1, and wipes retired plaintext secrets. Safe to call
     * from [android.app.Activity.onCreate]: failures are swallowed so a locked
     * Keystore cannot crash launch.
     */
    fun warmup(context: Context) {
        try {
            val masterKeyAlias = MasterKeys.getOrCreate(MasterKeys.AES256_GCM_SPEC)
            val prefs = EncryptedSharedPreferences.create(
                NativeSecureStorePolicy.PREFS_NAME,
                masterKeyAlias,
                context.applicationContext,
                EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
            )
            val editor = prefs.edit()
            val expected = NativeSecureStorePolicy.CURRENT_SCHEMA_VERSION.toString()
            if (prefs.getString(NativeSecureStorePolicy.SCHEMA_VERSION_KEY, null) != expected) {
                editor.putString(NativeSecureStorePolicy.SCHEMA_VERSION_KEY, expected)
            }
            for (key in NativeSecureStorePolicy.retiredKeys) {
                if (prefs.contains(key)) editor.remove(key)
            }
            editor.apply()
        } catch (e: Exception) {
            Log.w(TAG, "Secure store warmup failed: ${e.message}")
        }
    }
}
