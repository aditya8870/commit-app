package com.commit.app

import android.content.Context
import android.provider.Settings
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import java.security.MessageDigest
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Encrypted storage for the installation credential and ID.
 *
 * Values are encrypted with AES-256-GCM. The key is created inside the
 * Android Keystore and cannot be read or exported, not even by Commit.
 * Only the encrypted text is written to disk, in its own preferences file
 * that is excluded from backup like everything else in the app.
 *
 * Nothing here is ever logged.
 */
object SecureStore {
    private const val KEY_ALIAS = "commit_installation_v1"
    private const val PREFS = "commit_secure"
    private const val TRANSFORMATION = "AES/GCM/NoPadding"
    private const val IV_BYTES = 12
    private const val TAG_BITS = 128

    private fun prefs(ctx: Context) =
        ctx.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getEntry(KEY_ALIAS, null) as? KeyStore.SecretKeyEntry)?.let { return it.secretKey }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(
            KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build()
        )
        return generator.generateKey()
    }

    /** Returns false if the value could not be stored. */
    @Synchronized
    fun write(ctx: Context, name: String, value: String): Boolean {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val sealed = cipher.iv + cipher.doFinal(value.toByteArray(Charsets.UTF_8))
        return prefs(ctx).edit().putString(name, Base64.encodeToString(sealed, Base64.NO_WRAP)).commit()
    }

    /** The stored value, or null if there is none or it can no longer be decrypted. */
    @Synchronized
    fun read(ctx: Context, name: String): String? {
        val stored = prefs(ctx).getString(name, null) ?: return null
        return try {
            val sealed = Base64.decode(stored, Base64.NO_WRAP)
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(TAG_BITS, sealed, 0, IV_BYTES))
            String(cipher.doFinal(sealed, IV_BYTES, sealed.size - IV_BYTES), Charsets.UTF_8)
        } catch (e: Exception) {
            // The key is gone (for example after a restore) or the value is damaged.
            null
        }
    }

    @Synchronized
    fun delete(ctx: Context, name: String): Boolean = prefs(ctx).edit().remove(name).commit()
}

/**
 * The value Commit sends so the server can recognise this phone after a
 * reinstall. The raw Android identifier never leaves this function: it is
 * not returned, stored or logged. Only its SHA-256 hash is handed on.
 */
object RecoveryMaterial {
    private const val PREFIX = "commit-recovery-v1:"

    /** Identifier some old devices all shared; useless for telling phones apart. */
    private const val KNOWN_BAD_ID = "9774d56d682e549c"

    /** 64 lowercase hex characters: SHA-256("commit-recovery-v1:" + androidId). */
    fun hash(androidId: String): String =
        MessageDigest.getInstance("SHA-256")
            .digest((PREFIX + androidId).toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }

    /** Null when the phone has no usable identifier; recovery is then unavailable. */
    fun forThisDevice(ctx: Context): String? {
        val id = try {
            Settings.Secure.getString(ctx.contentResolver, Settings.Secure.ANDROID_ID)
        } catch (e: Exception) {
            null
        }
        if (id.isNullOrBlank() || id == KNOWN_BAD_ID) return null
        return hash(id)
    }
}
