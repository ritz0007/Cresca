package com.cresca.app

import org.junit.Assert.*
import org.junit.Test

/**
 * Stress tests for call-handling breakpoints.
 * Pure logic only (no emulator): verifies mode detection never crashes
 * and play-while-in-call decisions are safe.
 *
 * AudioManager modes (literals to keep JVM tests Android-free):
 * INVALID=-2, CURRENT=-1, NORMAL=0, RINGTONE=1, IN_CALL=2, IN_COMMUNICATION=3
 */
class CallGuardTest {

    @Test
    fun callModes_detected() {
        assertTrue(CallGuard.isCallMode(2))
        assertTrue(CallGuard.isCallMode(3))
        assertTrue(CallGuard.isCallMode(1))
        assertFalse(CallGuard.isCallMode(0))
        assertFalse(CallGuard.isCallMode(-2))
    }

    @Test
    fun callModes_stress_allInts() {
        // Stress: every int mode value must return without throwing.
        for (m in -10..20) {
            try {
                CallGuard.isCallMode(m)
            } catch (e: Exception) {
                fail("isCallMode threw for $m")
            }
        }
        // Random fuzz.
        val rnd = java.util.Random(7)
        repeat(2000) {
            CallGuard.isCallMode(rnd.nextInt())
        }
    }

    @Test
    fun normalMode_neverTreatedAsCall() {
        // Resume-after-call must only fire from call modes, never NORMAL.
        assertFalse(CallGuard.isCallMode(0))
    }

    @Test
    fun gate_defersPlayAndServiceInCall() {
        // The RemoteServiceException crash: starting playback mid-call while
        // focus is locked. Gate must defer taps and block service starts.
        assertEquals(
            CallGuard.CallPlayAction.DEFER_UNTIL_CALL_END,
            CallGuard.CallPlaybackGate.actionForTap(true)
        )
        assertEquals(
            CallGuard.CallPlayAction.START_NOW,
            CallGuard.CallPlaybackGate.actionForTap(false)
        )
        assertFalse(CallGuard.CallPlaybackGate.shouldStartForegroundService(true))
        assertTrue(CallGuard.CallPlaybackGate.shouldStartForegroundService(false))
    }

    @Test
    fun gate_stress_neverThrows() {
        repeat(1000) {
            CallGuard.CallPlaybackGate.actionForTap(it % 2 == 0)
            CallGuard.CallPlaybackGate.shouldStartForegroundService(it % 3 == 0)
        }
    }
}
