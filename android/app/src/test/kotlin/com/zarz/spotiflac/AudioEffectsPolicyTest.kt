package com.zarz.spotiflac

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AudioEffectsPolicyTest {
    private val tenBands = listOf(31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000)

    @Test
    fun cutoffsAreOctaveEdgesCappedAtTheAudibleLimit() {
        val cutoffs = AudioEffectsPolicy.cutoffFrequencies(tenBands)
        assertEquals(10, cutoffs.size)
        assertEquals(31f * kotlin.math.sqrt(2f), cutoffs[0], 0.01f)
        assertEquals(1000f * kotlin.math.sqrt(2f), cutoffs[5], 0.01f)
        assertEquals(AudioEffectsPolicy.MAX_CUTOFF_HZ, cutoffs[9], 0f)
        for (i in 1 until cutoffs.size) assertTrue(cutoffs[i] > cutoffs[i - 1])
    }

    @Test
    fun strengthAndGainConversionsClamp() {
        assertEquals(0.toShort(), AudioEffectsPolicy.strengthPermille(-1.0))
        assertEquals(500.toShort(), AudioEffectsPolicy.strengthPermille(0.5))
        assertEquals(1000.toShort(), AudioEffectsPolicy.strengthPermille(7.0))
        assertEquals(0, AudioEffectsPolicy.enhancerGainMb(-3.0))
        assertEquals(650, AudioEffectsPolicy.enhancerGainMb(6.5))
        assertEquals(1200, AudioEffectsPolicy.enhancerGainMb(99.0))
    }

    @Test
    fun identityMappingWhenDeviceBandsMatch() {
        val gains = listOf(1.0, 2.0, 3.0, 4.0, 5.0, -1.0, -2.0, -3.0, -4.0, -5.0)
        val levels = AudioEffectsPolicy.mapToDeviceBands(
            requestedCentersHz = tenBands,
            requestedGainsDb = gains,
            deviceCentersHz = tenBands,
            minMb = -1500,
            maxMb = 1500,
        )
        assertArrayEquals(
            shortArrayOf(100, 200, 300, 400, 500, -100, -200, -300, -400, -500),
            levels,
        )
    }

    @Test
    fun fiveBandDeviceFollowsTheCurveShapeAndClamps() {
        // Bass-boost curve.
        val gains = listOf(12.0, 10.0, 8.0, 4.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0)
        val device = listOf(60, 230, 910, 3600, 14000)
        val levels = AudioEffectsPolicy.mapToDeviceBands(
            requestedCentersHz = tenBands,
            requestedGainsDb = gains,
            deviceCentersHz = device,
            minMb = -600,
            maxMb = 600,
        )
        assertEquals(5, levels.size)
        assertEquals(600.toShort(), levels[0]) // clamped to device max
        assertTrue(levels[1] > levels[2])
        assertEquals(0.toShort(), levels[3])
        assertEquals(0.toShort(), levels[4])
    }

    @Test
    fun outOfRangeDeviceBandUsesNearestRequestedBand() {
        val levels = AudioEffectsPolicy.mapToDeviceBands(
            requestedCentersHz = listOf(1000),
            requestedGainsDb = listOf(3.0),
            deviceCentersHz = listOf(50, 16000),
            minMb = -1500,
            maxMb = 1500,
        )
        assertArrayEquals(shortArrayOf(300, 300), levels)
    }

    @Test
    fun emptyInputsYieldSilence() {
        val levels = AudioEffectsPolicy.mapToDeviceBands(
            requestedCentersHz = emptyList(),
            requestedGainsDb = emptyList(),
            deviceCentersHz = listOf(60, 230),
            minMb = -1500,
            maxMb = 1500,
        )
        assertArrayEquals(shortArrayOf(0, 0), levels)
    }

    @Test
    fun chainIsOnlyWantedWhenEnabledAndNonNeutral() {
        val flat = List(10) { 0.0 }
        assertFalse(
            AudioEffectsPolicy.chainWanted(
                enabled = false, bandGainsDb = listOf(3.0), bassBoost = 1.0,
                virtualizer = 1.0, enhancerGainDb = 3.0,
                compressorEnabled = true, limiterEnabled = true,
            ),
        )
        assertFalse(
            AudioEffectsPolicy.chainWanted(
                enabled = true, bandGainsDb = flat, bassBoost = 0.0,
                virtualizer = 0.0, enhancerGainDb = 0.0,
                compressorEnabled = false, limiterEnabled = false,
            ),
        )
        assertTrue(
            AudioEffectsPolicy.chainWanted(
                enabled = true, bandGainsDb = flat, bassBoost = 0.0,
                virtualizer = 0.0, enhancerGainDb = 0.0,
                compressorEnabled = false, limiterEnabled = true,
            ),
        )
        assertTrue(
            AudioEffectsPolicy.chainWanted(
                enabled = true, bandGainsDb = listOf(0.0, 1.0), bassBoost = 0.0,
                virtualizer = 0.0, enhancerGainDb = 0.0,
                compressorEnabled = false, limiterEnabled = false,
            ),
        )
    }

    @Test
    fun effectChainCoversBothMusicPlayers() {
        assertEquals(listOf("music-player", "music-player-crossfade"), AudioEffectsPolicy.playerIds)
    }
}
