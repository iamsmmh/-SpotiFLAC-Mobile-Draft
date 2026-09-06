package com.zarz.spotiflac

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

class ReferenceCountedKeyedLockTest {
    @Test
    fun `registry releases an idle key after success and failure`() {
        val locks = ReferenceCountedKeyedLock<String>()

        assertEquals("done", locks.withLock("track.flac") { "done" })
        assertEquals(0, locks.retainedKeyCountForTesting())

        try {
            locks.withLock("failed.flac") { error("expected") }
        } catch (_: IllegalStateException) {
        }
        assertEquals(0, locks.retainedKeyCountForTesting())
    }

    @Test
    fun `same key is serialized and removed after queued callers leave`() {
        val locks = ReferenceCountedKeyedLock<String>()
        val pool = Executors.newFixedThreadPool(2)
        val firstEntered = CountDownLatch(1)
        val releaseFirst = CountDownLatch(1)
        val secondEntered = CountDownLatch(1)
        val active = AtomicInteger(0)
        val maximumActive = AtomicInteger(0)

        val first = pool.submit {
            locks.withLock("same") {
                val nowActive = active.incrementAndGet()
                maximumActive.updateAndGet { current -> maxOf(current, nowActive) }
                firstEntered.countDown()
                assertTrue(releaseFirst.await(5, TimeUnit.SECONDS))
                active.decrementAndGet()
            }
        }
        assertTrue(firstEntered.await(5, TimeUnit.SECONDS))

        val second = pool.submit {
            locks.withLock("same") {
                val nowActive = active.incrementAndGet()
                maximumActive.updateAndGet { current -> maxOf(current, nowActive) }
                secondEntered.countDown()
                active.decrementAndGet()
            }
        }

        assertFalse(secondEntered.await(100, TimeUnit.MILLISECONDS))
        assertEquals(1, locks.retainedKeyCountForTesting())
        releaseFirst.countDown()
        first.get(5, TimeUnit.SECONDS)
        second.get(5, TimeUnit.SECONDS)
        pool.shutdownNow()

        assertEquals(1, maximumActive.get())
        assertEquals(0, locks.retainedKeyCountForTesting())
    }

    @Test
    fun `different keys can run concurrently`() {
        val locks = ReferenceCountedKeyedLock<String>()
        val pool = Executors.newFixedThreadPool(2)
        val bothEntered = CountDownLatch(2)
        val release = CountDownLatch(1)

        val futures = listOf("one", "two").map { key ->
            pool.submit {
                locks.withLock(key) {
                    bothEntered.countDown()
                    assertTrue(bothEntered.await(5, TimeUnit.SECONDS))
                    assertTrue(release.await(5, TimeUnit.SECONDS))
                }
            }
        }

        assertTrue(bothEntered.await(5, TimeUnit.SECONDS))
        assertEquals(2, locks.retainedKeyCountForTesting())
        release.countDown()
        futures.forEach { it.get(5, TimeUnit.SECONDS) }
        pool.shutdownNow()
        assertEquals(0, locks.retainedKeyCountForTesting())
    }
}
