package com.zarz.spotiflac

import kotlin.math.abs
import kotlin.math.ln
import kotlin.math.roundToInt
import kotlin.math.sqrt

/**
 * Pure unit conversions and band mapping for the native audio effect chain.
 * Kept free of android.media types so it can be unit-tested on the JVM.
 */
internal object AudioEffectsPolicy {
    /** Highest cutoff DynamicsProcessing accepts for the last EQ band. */
    const val MAX_CUTOFF_HZ = 20000f

    /** Strength units used by BassBoost / Virtualizer (0..1000 permille). */
    const val MAX_STRENGTH = 1000

    /**
     * Upper cutoff frequency of each octave band centred at [centersHz]:
     * centre × √2, capped so the top band ends at the audible limit.
     */
    fun cutoffFrequencies(centersHz: List<Int>): FloatArray {
        val cutoffs = FloatArray(centersHz.size)
        for (i in centersHz.indices) {
            val cutoff = centersHz[i].toFloat() * sqrt(2f)
            cutoffs[i] = if (cutoff > MAX_CUTOFF_HZ || i == centersHz.lastIndex) {
                MAX_CUTOFF_HZ
            } else {
                cutoff
            }
        }
        return cutoffs
    }

    /** Clamps a 0..1 strength to the platform's 0..1000 range. */
    fun strengthPermille(strength: Double): Short {
        val clamped = strength.coerceIn(0.0, 1.0)
        return (clamped * MAX_STRENGTH).roundToInt().coerceIn(0, MAX_STRENGTH).toShort()
    }

    /** Loudness enhancer gain: dB → millibels, never negative. */
    fun enhancerGainMb(gainDb: Double): Int =
        (gainDb.coerceIn(0.0, 12.0) * 100).roundToInt()

    /**
     * Maps the ten requested band gains onto a device equalizer with
     * arbitrary band centres (typically 5). Each device band takes the
     * distance-weighted (log-frequency) average of the requested bands
     * closest to it, so a 5-band device still follows the curve's shape.
     *
     * @return one gain in millibels per device band, clamped to
     *   [minMb, maxMb].
     */
    fun mapToDeviceBands(
        requestedCentersHz: List<Int>,
        requestedGainsDb: List<Double>,
        deviceCentersHz: List<Int>,
        minMb: Int,
        maxMb: Int,
    ): ShortArray {
        val result = ShortArray(deviceCentersHz.size)
        if (requestedCentersHz.isEmpty() || requestedGainsDb.isEmpty()) return result
        val count = minOf(requestedCentersHz.size, requestedGainsDb.size)
        for ((d, deviceHz) in deviceCentersHz.withIndex()) {
            val deviceLog = ln(deviceHz.coerceAtLeast(1).toDouble())
            var weightSum = 0.0
            var gainSum = 0.0
            for (i in 0 until count) {
                val distance = abs(ln(requestedCentersHz[i].coerceAtLeast(1).toDouble()) - deviceLog)
                // Bands within one octave (ln 2) contribute; nearer ones more.
                val weight = (ln(2.0) - distance).coerceAtLeast(0.0)
                if (weight <= 0.0) continue
                weightSum += weight
                gainSum += weight * requestedGainsDb[i]
            }
            val gainDb = if (weightSum > 0.0) {
                gainSum / weightSum
            } else {
                // No band within an octave: use the nearest one.
                var nearest = 0
                var nearestDistance = Double.MAX_VALUE
                for (i in 0 until count) {
                    val distance = abs(ln(requestedCentersHz[i].coerceAtLeast(1).toDouble()) - deviceLog)
                    if (distance < nearestDistance) {
                        nearestDistance = distance
                        nearest = i
                    }
                }
                requestedGainsDb[nearest]
            }
            result[d] = (gainDb * 100).roundToInt().coerceIn(minMb, maxMb).toShort()
        }
        return result
    }

    /** Player ids whose sessions carry the effect chain. */
    val playerIds = listOf("music-player", "music-player-crossfade")

    /**
     * Whether the chain should be attached at all. When disabled, or when
     * every stage is neutral, effects are released so the audio path is
     * bit-identical to the stock player.
     */
    fun chainWanted(
        enabled: Boolean,
        bandGainsDb: List<Double>,
        bassBoost: Double,
        virtualizer: Double,
        enhancerGainDb: Double,
        compressorEnabled: Boolean,
        limiterEnabled: Boolean,
    ): Boolean {
        if (!enabled) return false
        return bandGainsDb.any { it != 0.0 } ||
            bassBoost > 0.0 ||
            virtualizer > 0.0 ||
            enhancerGainDb > 0.0 ||
            compressorEnabled ||
            limiterEnabled
    }
}
