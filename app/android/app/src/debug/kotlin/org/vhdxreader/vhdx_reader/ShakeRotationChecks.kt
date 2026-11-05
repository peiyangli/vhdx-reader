package org.vhdxreader.vhdx_reader

import kotlin.math.*

object ShakeRotationChecks {
    private fun assertTrue(value: Boolean) { check(value) }
    private fun assertNull(value: Any?) { check(value == null) { "Expected null, got $value" } }
    private fun assertEquals(expected: Any?, actual: Any?) { check(expected == actual) { "Expected $expected, got $actual" } }
    @JvmStatic fun run(): List<String> {
        val checks = listOf(
            ::twoToThreeShakesThenSteadyConfirmsBothLandscapeSidesAndPortrait,
            ::singleShakeSmallJitterAndFlatDeviceDoNotRotate,
            ::sameAxisAndChangedMindDoNotRotate,
            ::noRotationBeforeSettling,
            ::resetAndTimeGapDiscardPartialGesture,
            ::cooldownRejectsImmediatelyRepeatedGesture)
        return checks.map { it(); it.name }
    }

    private fun trace(target: Int = 1, pulsesMs: Int = 1000, amplitude: Double = 8.0,
                      flat: Boolean = false, settleTarget: Int = target,
                      detector: ShakeRotationDetector = ShakeRotationDetector(),
                      start: Long = 0, current: Int = 0): List<Int> {
        val events = mutableListOf<Int>()
        for (t in 0..(1600 + pulsesMs) step 20) {
            val direction = if (t >= 800 + pulsesMs) settleTarget else target
            var x = if (direction == 1) 9.81 else if (direction == 3) -9.81 else 0.0
            var y = if (direction == 0) 9.81 else if (direction == 2) -9.81 else 0.0
            val shaking = if (t in 800 until 800 + pulsesMs)
                amplitude * sin(2 * PI * 2.5 * (t - 800) / 1000.0) else 0.0
            if (target % 2 == 1) y += shaking else x += shaking
            detector.sample(start + t, if (flat) shaking else x, if (flat) 0.0 else y,
                if (flat) 9.81 else 0.0, current)?.let { events += it }
        }
        return events
    }
    private fun twoToThreeShakesThenSteadyConfirmsBothLandscapeSidesAndPortrait() {
        for (target in 0..3) assertEquals(listOf(target), trace(target = target, current = (target + 1) % 4))
    }
    private fun singleShakeSmallJitterAndFlatDeviceDoNotRotate() {
        assertTrue(trace(pulsesMs = 400).isEmpty())
        assertTrue(trace(amplitude = 2.0).isEmpty())
        assertTrue(trace(flat = true).isEmpty())
    }
    private fun sameAxisAndChangedMindDoNotRotate() {
        assertTrue(trace(current = 1).isEmpty())
        assertTrue(trace(settleTarget = 0).isEmpty())
    }
    private fun noRotationBeforeSettling() {
        val detector = ShakeRotationDetector()
        for (t in 0..1800 step 20) {
            val shaking = if (t >= 800) 8 * sin(2 * PI * 2.5 * (t - 800) / 1000) else 0.0
            assertNull(detector.sample(t.toLong(), 9.81, shaking, 0.0, 0))
        }
    }
    private fun resetAndTimeGapDiscardPartialGesture() {
        val detector = ShakeRotationDetector()
        assertTrue(trace(pulsesMs = 400, detector = detector).isEmpty())
        detector.reset()
        assertTrue(trace(pulsesMs = 400, detector = detector, start = 2100).isEmpty())
        assertTrue(trace(pulsesMs = 400, detector = detector, start = 5000).isEmpty())
    }
    private fun cooldownRejectsImmediatelyRepeatedGesture() {
        val detector = ShakeRotationDetector()
        assertEquals(listOf(1), trace(detector = detector))
        assertTrue(trace(detector = detector, start = 2620).isEmpty())
        assertEquals(listOf(1), trace(detector = detector, start = 5240))
    }
}
