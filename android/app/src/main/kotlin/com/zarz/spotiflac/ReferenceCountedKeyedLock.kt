package com.zarz.spotiflac

/**
 * Per-key monitor registry that removes idle entries after the last waiter
 * leaves. Calling [withLock] serializes actions for the same key without
 * retaining one monitor forever for every output path the process has seen.
 */
internal class ReferenceCountedKeyedLock<K> {
    private data class Entry(
        val monitor: Any = Any(),
        var references: Int = 0,
    )

    private val registryLock = Any()
    private val entries = mutableMapOf<K, Entry>()

    fun <T> withLock(key: K, action: () -> T): T {
        val entry = synchronized(registryLock) {
            entries.getOrPut(key) { Entry() }.also { it.references++ }
        }
        try {
            return synchronized(entry.monitor) { action() }
        } finally {
            synchronized(registryLock) {
                entry.references--
                check(entry.references >= 0) { "Keyed-lock reference count underflow" }
                if (entry.references == 0 && entries[key] === entry) {
                    entries.remove(key)
                }
            }
        }
    }

    internal fun retainedKeyCountForTesting(): Int = synchronized(registryLock) {
        entries.size
    }
}
