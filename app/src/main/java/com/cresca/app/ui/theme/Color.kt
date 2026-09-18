package com.cresca.app.ui.theme

import androidx.compose.ui.graphics.Color

// Apple Music Android palette
val AppleRed = Color(0xFFFA243C)
val AppleRedDark = Color(0xFFFC5C6E)

val AppleLightBackground = Color(0xFFFFFFFF)
val AppleLightSurface = Color(0xFFF2F2F6)      // grouped-list grey
val AppleLightCard = Color(0xFFFFFFFF)
val AppleLightText = Color(0xFF000000)
val AppleLightSubtext = Color(0xFF8E8E93)      // iOS secondary grey

val AppleDarkBackground = Color(0xFF000000)
val AppleDarkSurface = Color(0xFF1C1C1E)       // iOS dark card
val AppleDarkCard = Color(0xFF1C1C1E)
val AppleDarkText = Color(0xFFFFFFFF)
val AppleDarkSubtext = Color(0xFF98989F)

// Fake artwork gradients (until real thumbs load via Coil)
val ArtGradients = listOf(
    listOf(Color(0xFFFA243C), Color(0xFF7D0018)),
    listOf(Color(0xFF5E5CE6), Color(0xFF1B1B6B)),
    listOf(Color(0xFF64D2FF), Color(0xFF0A84FF)),
    listOf(Color(0xFFFF9F0A), Color(0xFFB25000)),
    listOf(Color(0xFF30D158), Color(0xFF0B5C2A)),
    listOf(Color(0xFFFF375F), Color(0xFFBF5AF2))
)
