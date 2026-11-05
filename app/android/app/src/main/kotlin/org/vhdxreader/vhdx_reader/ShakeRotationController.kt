package org.vhdxreader.vhdx_reader

import android.app.Activity
import android.content.pm.ActivityInfo
import android.content.res.Configuration
import android.database.ContentObserver
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.view.Surface

internal class ShakeRotationController(private val activity: Activity) : SensorEventListener {
    private val sensors = activity.getSystemService(SensorManager::class.java)
    private val accelerometer = sensors.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)
    private val preferences get() = activity.getSharedPreferences("reader_display", Activity.MODE_PRIVATE)
    private val detector = ShakeRotationDetector()
    private var resumed = false
    private var listening = false
    private var override = false
    private val observer = object : ContentObserver(Handler(Looper.getMainLooper())) {
        override fun onChange(selfChange: Boolean) { refresh(clearOverride = true) }
    }
    val available get() = accelerometer != null
    private val automatic get() = preferences.getString("direction", "automatic") == "automatic"
    private val enabled get() = preferences.getBoolean("shake_rotation", false)
    private val systemAutomatic get() = Settings.System.getInt(activity.contentResolver,
        Settings.System.ACCELEROMETER_ROTATION, 0) != 0

    fun resume() {
        resumed = true
        activity.contentResolver.registerContentObserver(
            Settings.System.getUriFor(Settings.System.ACCELEROMETER_ROTATION), false, observer)
        activity.contentResolver.registerContentObserver(
            Settings.System.getUriFor(Settings.System.USER_ROTATION), false, observer)
        refresh()
    }
    fun pause() {
        resumed = false
        activity.contentResolver.unregisterContentObserver(observer)
        refresh(clearOverride = true)
    }
    fun refresh(clearOverride: Boolean = false) {
        if (clearOverride && override) {
            override = false
            if (automatic) activity.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_FULL_USER
        }
        val wanted = resumed && activity.hasWindowFocus() && automatic && enabled &&
            !systemAutomatic && !activity.isInMultiWindowMode && available
        if (listening) sensors.unregisterListener(this)
        listening = wanted && sensors.registerListener(this, accelerometer, 20_000)
        detector.reset()
    }
    @Suppress("DEPRECATION")
    private fun rotation() = activity.windowManager.defaultDisplay.rotation

    private fun apply(target: Int) {
        val current = rotation()
        val landscape = activity.resources.configuration.orientation == Configuration.ORIENTATION_LANDSCAPE
        val naturalLandscape = if (current == Surface.ROTATION_0 || current == Surface.ROTATION_180)
            landscape else !landscape
        val choices = if (naturalLandscape) intArrayOf(
            ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE, ActivityInfo.SCREEN_ORIENTATION_PORTRAIT,
            ActivityInfo.SCREEN_ORIENTATION_REVERSE_LANDSCAPE, ActivityInfo.SCREEN_ORIENTATION_REVERSE_PORTRAIT
        ) else intArrayOf(
            ActivityInfo.SCREEN_ORIENTATION_PORTRAIT, ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE,
            ActivityInfo.SCREEN_ORIENTATION_REVERSE_PORTRAIT, ActivityInfo.SCREEN_ORIENTATION_REVERSE_LANDSCAPE
        )
        override = true
        activity.requestedOrientation = choices[target]
    }
    override fun onSensorChanged(event: SensorEvent) {
        if (!listening || activity.isInMultiWindowMode) return
        detector.sample(event.timestamp / 1_000_000,
            event.values[0].toDouble(), event.values[1].toDouble(), event.values[2].toDouble(), rotation())
            ?.let { apply(it) }
    }
    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}

    // Debug-only channel supplies reproducible samples; release has no caller.
    fun debugSamples(samples: List<List<Number>>): Int {
        check(BuildConfig.DEBUG)
        if (!resumed || !automatic || !enabled || activity.isInMultiWindowMode) return 0
        sensors.unregisterListener(this); listening = false
        detector.reset()
        var rotations = 0
        for (sample in samples) {
            val target = detector.sample(sample[0].toLong(), sample[1].toDouble(),
                sample[2].toDouble(), sample[3].toDouble(), rotation())
            if (target != null) { apply(target); rotations++ }
        }
        refresh()
        return rotations
    }
}
