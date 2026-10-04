package com.commit.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** The hash sent to the server must match the Phase 3 API contract exactly. */
class RecoveryMaterialTest {
    @Test
    fun matchesTheContractVector() {
        // SHA-256("commit-recovery-v1:3f9a1c0b7e5d2468"), computed independently.
        assertEquals(
            "f6e4ce1ec831e720ada38270047ac2e74bd038d78daaf2ecefa621cb4db79e6a",
            RecoveryMaterial.hash("3f9a1c0b7e5d2468")
        )
    }

    @Test
    fun isSixtyFourLowercaseHexCharacters() {
        assertTrue(Regex("^[0-9a-f]{64}$").matches(RecoveryMaterial.hash("abc")))
    }

    @Test
    fun doesNotContainTheRawIdentifierAndDiffersPerDevice() {
        val id = "3f9a1c0b7e5d2468"
        assertTrue(!RecoveryMaterial.hash(id).contains(id))
        assertNotEquals(RecoveryMaterial.hash(id), RecoveryMaterial.hash("3f9a1c0b7e5d2469"))
    }
}
