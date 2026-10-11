package dev.fredol.open_tv

import android.app.Activity
import android.content.Context
import android.media.AudioManager
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.view.View
import android.view.WindowManager
import android.widget.ImageView
import android.widget.ProgressBar
import kotlin.math.roundToInt

// Right-side drags change the media volume, left-side drags change this
// window's brightness. Shows a small level indicator while dragging.
class PlayerGestureController(
    private val activity: Activity,
    private val indicator: View,
    private val indicatorIcon: ImageView,
    private val indicatorLevel: ProgressBar,
) : PlayerGestureLayout.Listener {

    companion object {
        const val INDICATOR_HIDE_DELAY_MS = 700L
        const val MIN_BRIGHTNESS = 0.01f
        const val SYSTEM_BRIGHTNESS_MAX = 255f
    }

    private enum class Target { VOLUME, BRIGHTNESS }

    private val audioManager = activity.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private val maxVolume = audioManager.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
    private val handler = Handler(Looper.getMainLooper())
    private val hideIndicator = Runnable { indicator.visibility = View.GONE }

    private var target = Target.VOLUME
    // Tracked as a float so slow drags accumulate between volume steps.
    private var level = 0f

    override fun onVerticalDragStart(leftSide: Boolean): Boolean {
        target = if (leftSide) Target.BRIGHTNESS else Target.VOLUME
        level = when (target) {
            Target.VOLUME -> audioManager.getStreamVolume(AudioManager.STREAM_MUSIC).toFloat() / maxVolume
            Target.BRIGHTNESS -> currentBrightness()
        }
        handler.removeCallbacks(hideIndicator)
        indicator.visibility = View.VISIBLE
        updateIndicator()
        return true
    }

    override fun onVerticalDrag(delta: Float) {
        level = (level + delta).coerceIn(0f, 1f)
        when (target) {
            Target.VOLUME -> audioManager.setStreamVolume(
                AudioManager.STREAM_MUSIC,
                (level * maxVolume).roundToInt(),
                0,
            )
            Target.BRIGHTNESS -> setBrightness(level.coerceAtLeast(MIN_BRIGHTNESS))
        }
        updateIndicator()
    }

    override fun onVerticalDragEnd() {
        handler.postDelayed(hideIndicator, INDICATOR_HIDE_DELAY_MS)
    }

    // Hands brightness control back to the system.
    fun release() {
        handler.removeCallbacksAndMessages(null)
        setBrightness(WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE)
    }

    private fun currentBrightness(): Float {
        val override = activity.window.attributes.screenBrightness
        if (override >= 0) return override
        val system = Settings.System.getInt(
            activity.contentResolver,
            Settings.System.SCREEN_BRIGHTNESS,
            SYSTEM_BRIGHTNESS_MAX.toInt() / 2,
        )
        return (system / SYSTEM_BRIGHTNESS_MAX).coerceIn(0f, 1f)
    }

    private fun setBrightness(value: Float) {
        val window = activity.window
        window.attributes = window.attributes.apply { screenBrightness = value }
    }

    private fun updateIndicator() {
        val percent = (level * 100).roundToInt()
        indicatorLevel.progress = percent
        indicatorIcon.setImageResource(
            when {
                target == Target.BRIGHTNESS -> R.drawable.ic_player_brightness
                percent == 0 -> R.drawable.ic_player_volume_off
                else -> R.drawable.ic_player_volume
            }
        )
    }
}
