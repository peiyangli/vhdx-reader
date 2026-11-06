package org.vhdxreader.vhdx_reader

import android.app.Activity
import android.app.KeyguardManager
import android.content.Context
import android.hardware.biometrics.BiometricManager
import android.hardware.biometrics.BiometricPrompt
import android.os.Build
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import java.lang.ref.WeakReference
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/** One native prompt per saved unlock; no reusable authorization is exposed to Dart. */
internal object VaultAuthentication {
    private val main = Handler(Looper.getMainLooper())
    private var activity = WeakReference<MainActivity>(null)
    private var pending: Attempt? = null // Main thread only.
    private var nextRequestCode = 4300
    private class Attempt(val host: MainActivity) {
        val done = CountDownLatch(1)
        val completed = AtomicBoolean(false)
        val result = AtomicInteger(2)
        val cancellation = CancellationSignal()
        var requestCode = -1
        fun finish(code: Int) {
            if (completed.compareAndSet(false, true)) {
                result.set(code)
                done.countDown()
            }
        }
    }
    fun attach(host: MainActivity) { activity = WeakReference(host) }
    fun detach(host: MainActivity) {
        if (activity.get() === host) activity.clear()
        pending?.takeIf { it.host === host }?.let {
            it.finish(1)
            it.cancellation.cancel()
            pending = null
        }
    }
    // Called by the Rust worker, never from the Android UI thread.
    fun authenticate(): Int {
        if (Looper.myLooper() == Looper.getMainLooper()) return 2
        val ready = CountDownLatch(1)
        val holder = java.util.concurrent.atomic.AtomicReference<Attempt?>()
        val expired = AtomicBoolean(false)
        main.post {
            val host = activity.get()
            if (!expired.get() && host != null && !host.isFinishing && !host.isDestroyed &&
                host.hasWindowFocus() && pending == null) {
                val attempt = Attempt(host)
                holder.set(attempt)
                pending = attempt
                start(attempt)
            }
            ready.countDown()
        }
        try {
            if (!ready.await(10, TimeUnit.SECONDS)) return 2
            val attempt = holder.get() ?: return 2
            if (!attempt.done.await(120, TimeUnit.SECONDS)) attempt.finish(1)
            return attempt.result.get()
        } finally {
            expired.set(true)
            main.post {
                holder.get()?.let {
                    it.finish(1)
                    it.cancellation.cancel()
                    if (pending === it) pending = null
                }
            }
        }
    }
    @Suppress("DEPRECATION")
    private fun start(attempt: Attempt) {
        try {
            val host = attempt.host
            val keyguard = host.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
            if (!keyguard.isDeviceSecure || keyguard.isDeviceLocked) { attempt.finish(2); return }
            if (Build.VERSION.SDK_INT >= 30) {
                BiometricPrompt.Builder(host)
                    .setTitle("验证身份以解锁 BitLocker")
                    .setSubtitle("使用指纹、人脸或设备锁屏密码")
                    .setAllowedAuthenticators(BiometricManager.Authenticators.BIOMETRIC_STRONG or
                        BiometricManager.Authenticators.DEVICE_CREDENTIAL)
                    .build().authenticate(attempt.cancellation, host.mainExecutor,
                        object : BiometricPrompt.AuthenticationCallback() {
                            override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                                attempt.finish(if (!host.isFinishing && !host.isDestroyed && !keyguard.isDeviceLocked) 0 else 1)
                            }
                            override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                                attempt.finish(1)
                            }
                            // A failed scan is not terminal: let the system offer a retry or PIN.
                        })
            } else {
                // API 24–29: reliable system PIN/password/pattern fallback without a biometric dependency.
                val intent = keyguard.createConfirmDeviceCredentialIntent(
                    "验证身份以解锁 BitLocker", "请输入设备锁屏 PIN、密码或图案")
                if (intent == null || nextRequestCode > 65535) { attempt.finish(2); return }
                // Never reuse a request code: a late result cannot approve a newer attempt.
                attempt.requestCode = nextRequestCode++
                host.startActivityForResult(intent, attempt.requestCode)
            }
        } catch (_: Exception) { attempt.finish(2) }
    }
    fun onActivityResult(host: MainActivity, requestCode: Int, resultCode: Int): Boolean {
        val attempt = pending ?: return false
        if (attempt.host !== host || attempt.requestCode != requestCode) return false
        attempt.finish(if (resultCode == Activity.RESULT_OK && !host.isFinishing && !host.isDestroyed) 0 else 1)
        return true
    }
}
