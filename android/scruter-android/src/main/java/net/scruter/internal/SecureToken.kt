package net.scruter.internal

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * The team phone's device token at rest (docs/MOBILE.md §3.12): AES-256-GCM with a key that never leaves the
 * Android Keystore. Without a usable Keystore the token lives in memory only (the phone registers again next run).
 */
internal object SecureToken {
    private const val ALIAS = "net.scruter.team"

    private fun key(): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore")
        ks.load(null)
        (ks.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        val gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        gen.init(
            KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build(),
        )
        return gen.generateKey()
    }

    fun seal(plain: String): String? = try {
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.ENCRYPT_MODE, key())
        val iv = c.iv
        val ct = c.doFinal(plain.toByteArray(Charsets.UTF_8))
        Base64.encodeToString(iv + ct, Base64.NO_WRAP)
    } catch (e: Exception) {
        Log.d("keystore unavailable: the team token is kept in memory only")
        null
    }

    fun open(sealed: String): String? = try {
        val all = Base64.decode(sealed, Base64.NO_WRAP)
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, all, 0, 12))
        String(c.doFinal(all, 12, all.size - 12), Charsets.UTF_8)
    } catch (e: Exception) {
        null
    }

    fun delete() {
        try {
            val ks = KeyStore.getInstance("AndroidKeyStore")
            ks.load(null)
            ks.deleteEntry(ALIAS)
        } catch (e: Exception) {
            Log.d("keystore: ${e.javaClass.simpleName}")
        }
    }
}
