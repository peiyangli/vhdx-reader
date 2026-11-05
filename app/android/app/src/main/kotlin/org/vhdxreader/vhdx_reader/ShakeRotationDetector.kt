package org.vhdxreader.vhdx_reader

import kotlin.math.*

/** Accelerometer only, monotonic milliseconds. No Android dependencies. */
internal class ShakeRotationDetector {
    private var time = -1L
    private val gravity = DoubleArray(3)
    private var candidate = -1
    private var candidateSince = 0L
    private var firstPeak = 0L
    private var lastPeak = -1000L
    private var peaks = 0
    private var lastVector = DoubleArray(3)
    private var above = false
    private var quietSince = -1L
    private var cooldownUntil = 0L

    fun reset() {
        time = -1; candidate = -1; peaks = 0; above = false
        quietSince = -1; lastPeak = -1000; cooldownUntil = 0
    }

    fun sample(now: Long, x: Double, y: Double, z: Double, current: Int): Int? {
        if (!x.isFinite() || !y.isFinite() || !z.isFinite()) return null
        val raw = doubleArrayOf(x, y, z)
        if (time < 0 || now <= time || now - time > 500) {
            reset(); raw.copyInto(gravity); time = now
            return null
        }
        val alpha = exp(-(now - time) / 350.0)
        time = now
        for (i in 0..2) gravity[i] = alpha * gravity[i] + (1 - alpha) * raw[i]
        val linear = DoubleArray(3) { raw[it] - gravity[it] }
        val motion = sqrt(linear.sumOf { it * it })
        val gx = gravity[0]; val gy = gravity[1]; val gz = gravity[2]
        val orientation = when {
            abs(gz) > 7.0 -> -1 // Flat/lying down: no unambiguous target.
            abs(gy) > 6 && abs(gy) > abs(gx) * 1.5 -> if (gy > 0) 0 else 2
            abs(gx) > 6 && abs(gx) > abs(gy) * 1.5 -> if (gx > 0) 1 else 3
            else -> -1
        }
        if (now < cooldownUntil) return null
        if (peaks > 0 && now - firstPeak > 2600) {
            peaks = 0; candidate = -1; quietSince = -1
        }
        // Establish target before shaking. During motion keep it until settled.
        if (peaks == 0 && orientation != candidate) {
            candidate = orientation; candidateSince = now
        }
        if (candidate < 0 || candidate % 2 == current % 2) {
            peaks = 0; above = motion > 4.5; return null
        }
        if (now - candidateSince < 400) { above = motion > 4.5; return null }
        if (motion < 2.0) above = false
        if (motion >= 4.5 && !above && now - lastPeak >= 100) {
            above = true
            val opposite = peaks == 0 || (0..2).sumOf { linear[it] * lastVector[it] } < 0
            if (opposite) {
                if (peaks == 0) firstPeak = now
                peaks++; lastPeak = now; lastVector = linear
            }
        }
        if (motion < 1.7 && orientation == candidate) {
            if (quietSince < 0) quietSince = now
        } else quietSince = -1
        if (peaks >= 4 && lastPeak - firstPeak >= 350 &&
            quietSince >= 0 && now - quietSince >= 450) {
            val target = candidate
            peaks = 0; candidate = -1; quietSince = -1
            cooldownUntil = now + 2500
            return target
        }
        return null
    }
}
