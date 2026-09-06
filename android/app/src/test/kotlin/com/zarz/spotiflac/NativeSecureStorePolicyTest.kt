package com.zarz.spotiflac

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NativeSecureStorePolicyTest {
    @Test
    fun schemaVersionIsOne() {
        assertEquals(1, NativeSecureStorePolicy.CURRENT_SCHEMA_VERSION)
        assertEquals(
            "spotiflac.secure.schema_version",
            NativeSecureStorePolicy.SCHEMA_VERSION_KEY,
        )
    }

    @Test
    fun namespacedKeysAreAllowed() {
        assertTrue(NativeSecureStorePolicy.isAllowedKey("spotiflac.token.access"))
        assertTrue(NativeSecureStorePolicy.isAllowedKey("spotiflac.secret.api"))
        assertTrue(NativeSecureStorePolicy.isAllowedKey("spotiflac.extsig.tidal"))
        assertTrue(
            NativeSecureStorePolicy.isAllowedKey(NativeSecureStorePolicy.SCHEMA_VERSION_KEY),
        )
    }

    @Test
    fun retiredSpotifySecretCanStillBeDeleted() {
        assertTrue(
            NativeSecureStorePolicy.isAllowedKey(
                NativeSecureStorePolicy.SPOTIFY_CLIENT_SECRET,
            ),
        )
        assertTrue(
            NativeSecureStorePolicy.retiredKeys.contains(
                NativeSecureStorePolicy.SPOTIFY_CLIENT_SECRET,
            ),
        )
    }

    @Test
    fun rejectsEmptyPrefixOnlyAndControlChars() {
        assertFalse(NativeSecureStorePolicy.isAllowedKey(""))
        assertFalse(NativeSecureStorePolicy.isAllowedKey("spotiflac.token."))
        assertFalse(NativeSecureStorePolicy.isAllowedKey("plaintext"))
        assertFalse(NativeSecureStorePolicy.isAllowedKey("spotiflac.token.x\n"))
        assertFalse(NativeSecureStorePolicy.isAllowedKey("a".repeat(129)))
    }

    @Test
    fun valueCapIs16KiB() {
        assertTrue(NativeSecureStorePolicy.isAllowedValue("ok"))
        assertFalse(
            NativeSecureStorePolicy.isAllowedValue(
                "x".repeat(NativeSecureStorePolicy.MAX_VALUE_BYTES + 1),
            ),
        )
    }
}
