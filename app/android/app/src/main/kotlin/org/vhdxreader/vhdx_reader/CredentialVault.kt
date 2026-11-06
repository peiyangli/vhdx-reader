package org.vhdxreader.vhdx_reader

import android.app.KeyguardManager
import android.content.Context
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import androidx.annotation.Keep
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Called only by the Rust worker over JNI. No password crosses Flutter. */
@Keep
class CredentialVault(context: Context) {
    private val keyguard = context.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
    private val file = AtomicFile(File(context.noBackupFilesDir, "bitlocker-vault-v1.aes"))
    private val alias = "org.vhdxreader.bitlocker.vault.v1"
    private val aad = alias.toByteArray(Charsets.UTF_8)
    fun authenticate(): Int = VaultAuthentication.authenticate()
    fun isUnlocked(): Boolean = !keyguard.isDeviceLocked
    private fun store(): KeyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
    private fun key(create: Boolean): SecretKey {
        (store().getKey(alias, null) as? SecretKey)?.let { return it }
        check(create) // Never replace a lost key while ciphertext still exists.
        val spec = KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256)
        // Older releases have documented unlocked-device key invalidation bugs.
        // On them the app checks Keyguard before every operation instead.
        if (Build.VERSION.SDK_INT >= 35) spec.setUnlockedDeviceRequired(true)
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply { init(spec.build()) }.generateKey()
    }
    fun load(): ByteArray? {
        check(isUnlocked())
        if (!file.baseFile.exists() && !File(file.baseFile.path + ".bak").exists()) return null
        val data = file.openRead().use { input ->
            check(input.channel.size() <= 4 * 1024 * 1024 + 64)
            input.readBytes()
        }
        check(data.size >= 29 && data[0] == 1.toByte())
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key(false), GCMParameterSpec(128, data.copyOfRange(1, 13)))
        cipher.updateAAD(aad)
        return cipher.doFinal(data, 13, data.size - 13)
    }
    fun save(data: ByteArray) {
        try {
            check(isUnlocked() && data.size <= 4 * 1024 * 1024)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, key(true))
            cipher.updateAAD(aad)
            val encrypted = cipher.doFinal(data)
            val output = file.startWrite()
            try {
                output.write(byteArrayOf(1)); output.write(cipher.iv); output.write(encrypted)
                file.finishWrite(output)
            } catch (e: Exception) { file.failWrite(output); throw e }
        } finally { data.fill(0) }
    }
    fun clear() {
        check(isUnlocked())
        file.delete()
        check(!file.baseFile.exists())
        store().deleteEntry(alias)
    }
}
