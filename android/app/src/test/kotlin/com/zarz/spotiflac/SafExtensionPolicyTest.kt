package com.zarz.spotiflac

import org.junit.Assert.assertEquals
import org.junit.Test

class SafExtensionPolicyTest {
    @Test
    fun `normalizes simple audio extensions`() {
        assertEquals(".flac", SafDownloadHandler.normalizeExt(" FLAC "))
        assertEquals(".m4a", SafDownloadHandler.normalizeExt(".M4A"))
        assertEquals(".aiff", SafDownloadHandler.normalizeExt("aiff"))
    }

    @Test
    fun `rejects malformed extension fragments`() {
        listOf(
            null,
            "",
            ".",
            "../flac",
            "flac/track",
            "flac?download=1",
            "tar.gz",
            "flac; charset=utf-8",
            "thisextensionisfartoolong",
        ).forEach { extension ->
            assertEquals("Unexpected extension: $extension", "", SafDownloadHandler.normalizeExt(extension))
        }
    }

    @Test
    fun `maps common final audio extensions to specific mime types`() {
        assertEquals("audio/ogg", SafDownloadHandler.mimeTypeForExt("ogg"))
        assertEquals("audio/aac", SafDownloadHandler.mimeTypeForExt("aac"))
        assertEquals("audio/wav", SafDownloadHandler.mimeTypeForExt("wav"))
        assertEquals("audio/aiff", SafDownloadHandler.mimeTypeForExt("aifc"))
        assertEquals("application/octet-stream", SafDownloadHandler.mimeTypeForExt("../flac"))
    }
}
