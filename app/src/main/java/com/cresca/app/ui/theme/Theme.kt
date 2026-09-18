package com.cresca.app.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable

private val AppleLightScheme = lightColorScheme(
    primary = AppleRed,
    onPrimary = AppleLightBackground,
    background = AppleLightBackground,
    onBackground = AppleLightText,
    surface = AppleLightBackground,
    onSurface = AppleLightText,
    surfaceVariant = AppleLightSurface,
    onSurfaceVariant = AppleLightSubtext,
    secondaryContainer = AppleLightSurface
)

private val AppleDarkScheme = darkColorScheme(
    primary = AppleRedDark,
    onPrimary = AppleDarkBackground,
    background = AppleDarkBackground,
    onBackground = AppleDarkText,
    surface = AppleDarkBackground,
    onSurface = AppleDarkText,
    surfaceVariant = AppleDarkSurface,
    onSurfaceVariant = AppleDarkSubtext,
    secondaryContainer = AppleDarkSurface
)

@Composable
fun AppleMusicTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    content: @Composable () -> Unit
) {
    MaterialTheme(
        colorScheme = if (darkTheme) AppleDarkScheme else AppleLightScheme,
        typography = AppleTypography,
        content = content
    )
}
