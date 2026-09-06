package com.zarz.spotiflac

import android.media.MediaPlayer
import android.media.audiofx.BassBoost
import android.media.audiofx.DynamicsProcessing
import android.media.audiofx.Equalizer
import android.media.audiofx.LoudnessEnhancer
import android.media.audiofx.Virtualizer
import android.os.Build
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.plugins.FlutterPlugin

/**
 * Attaches the system audio-effect chain (10-band EQ, bass boost,
 * virtualizer, loudness enhancer, compressor, limiter) to the audio sessions
 * of the app's music players.
 *
 * The players live inside the audioplayers plugin, which does not expose its
 * `MediaPlayer` audio session ids. They are read reflectively (the plugin's
 * classes are kept by proguard-rules.pro); when that fails on some future
 * plugin version the controller reports `attached = false` and the UI tells
 * the user instead of pretending the effects work.
 *
 * API 28+ uses [DynamicsProcessing] (exact octave bands, multi-band
 * compressor, limiter). Older devices fall back to [Equalizer] with the
 * requested curve mapped onto the device's bands; compressor/limiter are then
 * reported as unsupported.
 */
internal class AudioEffectsController(private val engineProvider: () -> FlutterEngine?) {
    companion object {
        /**
         * Process-wide instance. The Flutter engine (and the music players)
         * outlive the Activity, so the effect chain must too — a per-Activity
         * controller would attach a second, doubled chain after every
         * configuration change.
         */
        @Volatile
        private var engine: FlutterEngine? = null

        val shared: AudioEffectsController by lazy { AudioEffectsController { engine } }

        fun bind(flutterEngine: FlutterEngine) {
            engine = flutterEngine
        }
    }

    private class Chain(val sessionId: Int) {
        var dynamics: DynamicsProcessing? = null
        var equalizer: Equalizer? = null
        var bassBoost: BassBoost? = null
        var virtualizer: Virtualizer? = null
        var enhancer: LoudnessEnhancer? = null

        fun release() {
            for (effect in listOf(dynamics, equalizer, bassBoost, virtualizer, enhancer)) {
                try {
                    effect?.setEnabled(false)
                } catch (_: Exception) {}
                try {
                    effect?.release()
                } catch (_: Exception) {}
            }
            dynamics = null
            equalizer = null
            bassBoost = null
            virtualizer = null
            enhancer = null
        }
    }

    private val chains = HashMap<String, Chain>()
    private var dynamicsUnavailable = false

    private val dynamicsSupported: Boolean
        get() = Build.VERSION.SDK_INT >= Build.VERSION_CODES.P && !dynamicsUnavailable

    fun capabilities(): Map<String, Any?> = mapOf(
        "equalizer" to true,
        "bass_boost" to true,
        "virtualizer" to true,
        "enhancer" to true,
        "compressor" to dynamicsSupported,
        "limiter" to dynamicsSupported,
        "engine" to if (dynamicsSupported) "DynamicsProcessing" else "Equalizer",
        "attached_players" to chains.keys.sorted(),
    )

    /**
     * Applies [config] (see `AudioEffectsSettings.toPlatformMap` on the Dart
     * side) to every resolvable player session. Safe to call often; only the
     * effect parameters change when sessions are unchanged.
     */
    @Synchronized
    fun apply(config: Map<String, Any?>): Map<String, Any?> = applyInternal(config)

    @Synchronized
    fun release() {
        for (chain in chains.values) chain.release()
        chains.clear()
    }

    private fun applyInternal(config: Map<String, Any?>): Map<String, Any?> {
        val enabled = config["enabled"] == true
        val centers = intList(config["band_frequencies_hz"])
        val gains = doubleList(config["band_gains_db"])
        val bassBoost = doubleOf(config["bass_boost"])
        val virtualizer = doubleOf(config["virtualizer"])
        val enhancerGainDb = doubleOf(config["enhancer_gain_db"])
        val compressorEnabled = config["compressor_enabled"] == true
        val compressorThresholdDb = doubleOf(config["compressor_threshold_db"], -18.0)
        val compressorRatio = doubleOf(config["compressor_ratio"], 3.0)
        val limiterEnabled = config["limiter_enabled"] == true
        val limiterThresholdDb = doubleOf(config["limiter_threshold_db"], -1.0)

        val wanted = AudioEffectsPolicy.chainWanted(
            enabled = enabled,
            bandGainsDb = gains,
            bassBoost = bassBoost,
            virtualizer = virtualizer,
            enhancerGainDb = enhancerGainDb,
            compressorEnabled = compressorEnabled,
            limiterEnabled = limiterEnabled,
        )
        if (!wanted) {
            release()
            return mapOf("attached" to false, "players" to emptyList<String>(), "reason" to "chain idle")
        }

        val sessions = resolveSessionIds()
        // Drop chains whose player vanished or changed session.
        val stale = chains.filter { (id, chain) -> sessions[id] != chain.sessionId }.keys
        for (id in stale) {
            chains.remove(id)?.release()
        }
        if (sessions.isEmpty()) {
            return mapOf(
                "attached" to false,
                "players" to emptyList<String>(),
                "reason" to "no active player session",
            )
        }

        val attached = mutableListOf<String>()
        for ((id, sessionId) in sessions) {
            if (sessionId <= 0) continue
            val chain = chains.getOrPut(id) { Chain(sessionId) }
            try {
                configureChain(
                    chain = chain,
                    centers = centers,
                    gains = gains,
                    bassBoost = bassBoost,
                    virtualizer = virtualizer,
                    enhancerGainDb = enhancerGainDb,
                    compressorEnabled = compressorEnabled,
                    compressorThresholdDb = compressorThresholdDb,
                    compressorRatio = compressorRatio,
                    limiterEnabled = limiterEnabled,
                    limiterThresholdDb = limiterThresholdDb,
                )
                attached.add(id)
            } catch (e: Exception) {
                android.util.Log.w("SpotiFLAC", "Audio effects failed for $id: ${e.message}")
                chains.remove(id)?.release()
            }
        }
        return mapOf(
            "attached" to attached.isNotEmpty(),
            "players" to attached.sorted(),
            "engine" to if (dynamicsSupported) "DynamicsProcessing" else "Equalizer",
        )
    }

    private fun configureChain(
        chain: Chain,
        centers: List<Int>,
        gains: List<Double>,
        bassBoost: Double,
        virtualizer: Double,
        enhancerGainDb: Double,
        compressorEnabled: Boolean,
        compressorThresholdDb: Double,
        compressorRatio: Double,
        limiterEnabled: Boolean,
        limiterThresholdDb: Double,
    ) {
        val sessionId = chain.sessionId
        val eqActive = gains.any { it != 0.0 }
        val dynamicsActive = eqActive || compressorEnabled || limiterEnabled

        if (dynamicsSupported && Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            if (dynamicsActive) {
                val dp = chain.dynamics ?: try {
                    createDynamics(sessionId, centers.size.coerceAtLeast(1)).also { chain.dynamics = it }
                } catch (e: Exception) {
                    // Some OEM builds advertise but cannot instantiate the
                    // effect; degrade to the classic Equalizer for good.
                    android.util.Log.w("SpotiFLAC", "DynamicsProcessing unavailable: ${e.message}")
                    dynamicsUnavailable = true
                    null
                }
                if (dp != null) {
                    applyDynamics(
                        dp, centers, gains, compressorEnabled, compressorThresholdDb,
                        compressorRatio, limiterEnabled, limiterThresholdDb,
                    )
                }
            } else {
                chain.dynamics?.let {
                    try { it.setEnabled(false) } catch (_: Exception) {}
                    try { it.release() } catch (_: Exception) {}
                }
                chain.dynamics = null
            }
        }
        if (!dynamicsSupported) {
            if (eqActive) {
                val eq = chain.equalizer ?: Equalizer(0, sessionId).also { chain.equalizer = it }
                applyEqualizer(eq, centers, gains)
            } else {
                chain.equalizer?.let {
                    try { it.setEnabled(false) } catch (_: Exception) {}
                    try { it.release() } catch (_: Exception) {}
                }
                chain.equalizer = null
            }
        }

        if (bassBoost > 0.0) {
            val effect = chain.bassBoost ?: BassBoost(0, sessionId).also { chain.bassBoost = it }
            if (effect.strengthSupported) {
                effect.setStrength(AudioEffectsPolicy.strengthPermille(bassBoost))
            }
            effect.setEnabled(true)
        } else {
            chain.bassBoost?.let {
                try { it.setEnabled(false) } catch (_: Exception) {}
                try { it.release() } catch (_: Exception) {}
            }
            chain.bassBoost = null
        }

        if (virtualizer > 0.0) {
            val effect = chain.virtualizer ?: Virtualizer(0, sessionId).also { chain.virtualizer = it }
            if (effect.strengthSupported) {
                effect.setStrength(AudioEffectsPolicy.strengthPermille(virtualizer))
            }
            effect.setEnabled(true)
        } else {
            chain.virtualizer?.let {
                try { it.setEnabled(false) } catch (_: Exception) {}
                try { it.release() } catch (_: Exception) {}
            }
            chain.virtualizer = null
        }

        if (enhancerGainDb > 0.0) {
            val effect = chain.enhancer ?: LoudnessEnhancer(sessionId).also { chain.enhancer = it }
            effect.setTargetGain(AudioEffectsPolicy.enhancerGainMb(enhancerGainDb))
            effect.setEnabled(true)
        } else {
            chain.enhancer?.let {
                try { it.setEnabled(false) } catch (_: Exception) {}
                try { it.release() } catch (_: Exception) {}
            }
            chain.enhancer = null
        }
    }

    // Callers guard on Build.VERSION_CODES.P.
    private fun createDynamics(sessionId: Int, bandCount: Int): DynamicsProcessing {
        val config = DynamicsProcessing.Config.Builder(
            DynamicsProcessing.VARIANT_FAVOR_FREQUENCY_RESOLUTION,
            2, // channel count
            true, // preEq in use
            bandCount,
            true, // mbc in use
            1,
            false, // postEq
            0,
            true, // limiter in use
        ).build()
        return DynamicsProcessing(0, sessionId, config)
    }

    // Callers guard on Build.VERSION_CODES.P.
    private fun applyDynamics(
        dp: DynamicsProcessing,
        centers: List<Int>,
        gains: List<Double>,
        compressorEnabled: Boolean,
        compressorThresholdDb: Double,
        compressorRatio: Double,
        limiterEnabled: Boolean,
        limiterThresholdDb: Double,
    ) {
        val cutoffs = AudioEffectsPolicy.cutoffFrequencies(centers)
        val bandCount = minOf(cutoffs.size, gains.size)
        for (band in 0 until bandCount) {
            val eqBand = DynamicsProcessing.EqBand(true, cutoffs[band], gains[band].toFloat())
            dp.setPreEqBandAllChannelsTo(band, eqBand)
        }
        val preEq = dp.getPreEqByChannelIndex(0)
        preEq.isEnabled = gains.any { it != 0.0 }
        dp.setPreEqAllChannelsTo(preEq)

        val mbc = dp.getMbcByChannelIndex(0)
        mbc.isEnabled = compressorEnabled
        if (compressorEnabled && mbc.bandCount > 0) {
            val band = mbc.getBand(0)
            band.isEnabled = true
            band.cutoffFrequency = AudioEffectsPolicy.MAX_CUTOFF_HZ
            band.attackTime = 10f
            band.releaseTime = 120f
            band.ratio = compressorRatio.toFloat().coerceIn(1f, 20f)
            band.threshold = compressorThresholdDb.toFloat().coerceIn(-40f, 0f)
            band.kneeWidth = 6f
            band.noiseGateThreshold = -90f
            band.expanderRatio = 1f
            band.preGain = 0f
            // Make-up gain: recover a third of the reduction at the threshold
            // so engaging the compressor does not simply make things quieter.
            band.postGain = (-band.threshold * (1f - 1f / band.ratio) / 3f).coerceIn(0f, 12f)
            mbc.setBand(0, band)
        }
        dp.setMbcAllChannelsTo(mbc)

        val limiter = DynamicsProcessing.Limiter(
            true,
            limiterEnabled,
            0,
            1f,
            50f,
            10f,
            limiterThresholdDb.toFloat().coerceIn(-12f, 0f),
            0f,
        )
        dp.setLimiterAllChannelsTo(limiter)
        dp.setEnabled(true)
    }

    private fun applyEqualizer(eq: Equalizer, centers: List<Int>, gains: List<Double>) {
        val deviceBands = eq.numberOfBands.toInt()
        val deviceCenters = (0 until deviceBands).map { eq.getCenterFreq(it.toShort()) / 1000 }
        val range = eq.bandLevelRange
        val levels = AudioEffectsPolicy.mapToDeviceBands(
            requestedCentersHz = centers,
            requestedGainsDb = gains,
            deviceCentersHz = deviceCenters,
            minMb = range[0].toInt(),
            maxMb = range[1].toInt(),
        )
        for (band in 0 until deviceBands) {
            eq.setBandLevel(band.toShort(), levels[band])
        }
        eq.setEnabled(true)
    }

    /** playerId → audio session id, for every music player that currently exists. */
    private fun resolveSessionIds(): Map<String, Int> {
        val engine = engineProvider() ?: return emptyMap()
        val result = LinkedHashMap<String, Int>()
        try {
            @Suppress("UNCHECKED_CAST")
            val pluginClass = Class.forName("xyz.luan.audioplayers.AudioplayersPlugin") as Class<out FlutterPlugin>
            val plugin = engine.plugins.get(pluginClass) ?: return emptyMap()
            val playersField = plugin.javaClass.getDeclaredField("players").apply { isAccessible = true }
            val players = playersField.get(plugin) as? Map<*, *> ?: return emptyMap()
            for (id in AudioEffectsPolicy.playerIds) {
                val wrapped = players[id] ?: continue
                val mediaPlayer = findMediaPlayer(wrapped) ?: continue
                val sessionId = try {
                    mediaPlayer.audioSessionId
                } catch (_: Exception) {
                    0
                }
                if (sessionId > 0) result[id] = sessionId
            }
        } catch (e: Exception) {
            android.util.Log.w("SpotiFLAC", "Cannot resolve player audio sessions: ${e.message}")
        }
        return result
    }

    /** Walks WrappedPlayer.player (PlayerWrapper) → MediaPlayerWrapper.mediaPlayer. */
    private fun findMediaPlayer(wrapped: Any): MediaPlayer? {
        val inner = readField(wrapped, "player") ?: return null
        if (inner is MediaPlayer) return inner
        val candidate = readField(inner, "mediaPlayer") ?: readField(inner, "player")
        return candidate as? MediaPlayer
    }

    private fun readField(target: Any, name: String): Any? {
        var cls: Class<*>? = target.javaClass
        while (cls != null) {
            try {
                val field = cls.getDeclaredField(name)
                field.isAccessible = true
                return field.get(target)
            } catch (_: NoSuchFieldException) {
                cls = cls.superclass
            } catch (_: Exception) {
                return null
            }
        }
        return null
    }

    private fun intList(value: Any?): List<Int> =
        (value as? List<*>)?.mapNotNull { (it as? Number)?.toInt() } ?: emptyList()

    private fun doubleList(value: Any?): List<Double> =
        (value as? List<*>)?.mapNotNull { (it as? Number)?.toDouble() } ?: emptyList()

    private fun doubleOf(value: Any?, fallback: Double = 0.0): Double =
        (value as? Number)?.toDouble()?.takeIf { it.isFinite() } ?: fallback
}
