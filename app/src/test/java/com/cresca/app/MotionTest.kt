package com.cresca.app

import androidx.compose.animation.core.SpringSpec
import androidx.compose.animation.core.TweenSpec
import org.junit.Assert.*
import org.junit.Test

class MotionTest {

    @Test
    fun tabTransitions_existBothDirections() {
        for (on in listOf(true, false)) {
            for (fwd in listOf(true, false)) {
                assertNotNull(Motion.tabEnter(on, fwd))
                assertNotNull(Motion.tabExit(on, fwd))
            }
        }
    }

    @Test
    fun pressSpring_isGentle() {
        val spec = Motion.pressSpring<Float>()
        assertTrue(spec is SpringSpec)
        assertEquals(0.6f, (spec as SpringSpec<Float>).dampingRatio)
    }

    @Test
    fun pressTween_isSnappy() {
        val spec = Motion.pressTween()
        assertTrue(spec is TweenSpec)
        assertEquals(120, (spec as TweenSpec<Float>).durationMillis)
    }
}
