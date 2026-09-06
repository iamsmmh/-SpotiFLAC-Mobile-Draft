package com.zarz.spotiflac

import android.os.Process
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class NativeThreadPriorityTest {
    @Test
    fun downloadIsBackgroundSoALongQueueCannotStarveUi() {
        assertEquals(Process.THREAD_PRIORITY_BACKGROUND, NativeThreadPriority.DOWNLOAD)
    }

    @Test
    fun ffmpegIsSlightlyMoreFavourableThanDownload() {
        assertEquals(
            Process.THREAD_PRIORITY_BACKGROUND + Process.THREAD_PRIORITY_MORE_FAVORABLE,
            NativeThreadPriority.FFMPEG,
        )
        assertTrue(NativeThreadPriority.FFMPEG < NativeThreadPriority.DOWNLOAD)
    }

    @Test
    fun playbackStaysAtAudioPriority() {
        assertEquals(Process.THREAD_PRIORITY_AUDIO, NativeThreadPriority.PLAYBACK)
        assertTrue(NativeThreadPriority.PLAYBACK < NativeThreadPriority.FFMPEG)
    }
}
