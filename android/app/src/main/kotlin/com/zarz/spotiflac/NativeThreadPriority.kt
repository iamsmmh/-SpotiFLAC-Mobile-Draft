package com.zarz.spotiflac

import android.os.Process
import android.util.Log

/**
 * Native thread priorities for multi-hour download / FFmpeg / playback work.
 *
 * Download workers sit at [Process.THREAD_PRIORITY_BACKGROUND] so a 2-hour
 * queue cannot starve the UI or the mediaPlayback FGS. FFmpeg finalization
 * is one notch more favourable so encode/decrypt still completes, but never
 * at audio/UI priority. Playback stays at [Process.THREAD_PRIORITY_AUDIO].
 */
internal object NativeThreadPriority {
    const val DOWNLOAD = Process.THREAD_PRIORITY_BACKGROUND
    const val FFMPEG = Process.THREAD_PRIORITY_BACKGROUND + Process.THREAD_PRIORITY_MORE_FAVORABLE
    const val PLAYBACK = Process.THREAD_PRIORITY_AUDIO

    fun apply(priority: Int) {
        try {
            Process.setThreadPriority(priority)
        } catch (e: Exception) {
            Log.w("NativeThreadPriority", "Failed to set thread priority $priority: ${e.message}")
        }
    }

    fun applyForDownload() = apply(DOWNLOAD)

    fun applyForFfmpeg() = apply(FFMPEG)

    fun applyForPlayback() = apply(PLAYBACK)
}
