package com.cresca.app

import android.content.Context
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.waitForUpOrCancellation
import androidx.compose.runtime.Composable
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput

/** Kill-switch ambient: rows/cards read this, no signature churn. */
val LocalMotion = compositionLocalOf { true }

/**
 * One motion language for the whole app (middle path: noticeable, tasteful).
 * All specs flow through [motionOn]: Settings → Appearance → Motion toggle
 * (default ON, persisted). When off, every spec collapses to an instant
 * change — a single kill-switch with zero behavior drift.
 */
object Motion {
    const val PREF_KEY = "motion_on"

    fun isOn(ctx: Context): Boolean {
        return try {
            ctx.getSharedPreferences("cresca_prefs", Context.MODE_PRIVATE)
                .getBoolean(PREF_KEY, true)
        } catch (e: Exception) {
            true
        }
    }

    fun setOn(ctx: Context, on: Boolean) {
        try {
            ctx.getSharedPreferences("cresca_prefs", Context.MODE_PRIVATE)
                .edit().putBoolean(PREF_KEY, on).apply()
        } catch (e: Exception) {
        }
    }

    /** Standard content fade+rise (lists, banners, errors). */
    @Composable
    fun fadeRise(on: Boolean): androidx.compose.animation.EnterTransition {
        return remember(on) {
            if (on) fadeIn(tween(280)) + androidx.compose.animation.slideInVertically(tween(280)) { it / 3 }
            else fadeIn(tween(1))
        }
    }

    /** Tab switch: quick lateral drift in swipe direction, fade both ways. */
    fun tabEnter(on: Boolean, forward: Boolean) =
        if (on) fadeIn(tween(220)) + slideInHorizontally(tween(220)) { if (forward) it / 6 else -it / 6 }
        else fadeIn(tween(1))

    fun tabExit(on: Boolean, forward: Boolean) =
        if (on) fadeOut(tween(180)) + slideOutHorizontally(tween(180)) { if (forward) -it / 6 else it / 6 }
        else fadeOut(tween(1))

    /** Gentle press spring shared by play/like/transport/cards. */
    fun <T> pressSpring() = spring<T>(dampingRatio = 0.6f, stiffness = Spring.StiffnessMedium)

    fun pressTween() = tween<Float>(120)
}

/**
 * Press physics: scales to 0.94 while a finger is down, springs back on
 * release. Never consumes input (down is observed with requireUnconsumed =
 * false), so existing clickable/IconButton handlers fire untouched. Ripples
 * stay as-is. No-op when motion is off.
 */
@Composable
fun Modifier.pressScale(on: Boolean, pressedScale: Float = 0.94f): Modifier {
    if (!on) return this
    var target by remember { mutableFloatStateOf(1f) }
    val scale by androidx.compose.animation.core.animateFloatAsState(
        targetValue = target,
        animationSpec = if (target < 1f) Motion.pressTween() else Motion.pressSpring(),
        label = "press"
    )
    return this
        .graphicsLayer(scaleX = scale, scaleY = scale)
        .pointerInput(pressedScale) {
            awaitEachGesture {
                awaitFirstDown(requireUnconsumed = false)
                target = pressedScale
                waitForUpOrCancellation()
                target = 1f
            }
        }
}
