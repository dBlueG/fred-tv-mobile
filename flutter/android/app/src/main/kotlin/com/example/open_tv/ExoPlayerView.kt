package dev.fredol.open_tv

import android.app.Activity
import android.app.AlertDialog
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.content.res.ColorStateList
import android.graphics.Color
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import android.util.Rational
import android.view.KeyEvent
import android.view.LayoutInflater
import android.view.View
import android.widget.ImageView
import android.widget.ProgressBar
import android.widget.TextView
import android.widget.Toast
import androidx.media3.common.C
import androidx.media3.common.Format
import androidx.media3.common.ForwardingPlayer
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.TrackSelectionOverride
import androidx.media3.common.VideoSize
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.LoadControl
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.exoplayer.upstream.DefaultLoadErrorHandlingPolicy
import androidx.media3.exoplayer.util.EventLogger
import androidx.media3.session.MediaSession
import androidx.media3.ui.AspectRatioFrameLayout
import androidx.media3.ui.DefaultTimeBar
import androidx.media3.ui.PlayerView
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.platform.PlatformView
import java.util.Locale

class ExoPlayerView(
    activity: Activity,
    context: Context,
    messenger: BinaryMessenger,
    viewId: Int,
    params: Map<String, Any?>,
    private val onPipStateChanged: () -> Unit,
) : PlatformView, MethodChannel.MethodCallHandler, PlayerGestureLayout.ActionListener {

    private val isLive = params["isLive"] as? Boolean ?: false
    private var url = params["url"] as String
    private val startPositionMs = (params["startPositionMs"] as? Number)?.toLong() ?: 0L
    private var title = params["title"] as? String ?: ""
    private var image = params["image"] as? String
    // Player settings from Flutter
    private val volumeBrightnessGestures = params["volumeBrightnessGestures"] as? Boolean ?: true
    private val swipeToChangeChannel = params["swipeToChangeChannel"] as? Boolean ?: true
    private val canSwitchChannel = params["canSwitchChannel"] as? Boolean ?: false
    private val doubleTapSeek = params["doubleTapSeek"] as? Boolean ?: true
    private val seekIncrementMs = ((params["seekSeconds"] as? Number)?.toLong() ?: 10L) * 1000L
    private val keepAudioAfterPip = params["keepAudioAfterPip"] as? Boolean ?: false
    private val isEpisode = params["isEpisode"] as? Boolean ?: false
    private val autoplayNext = params["autoplayNext"] as? Boolean ?: true
    private val autoplayCountdownSeconds = (params["autoplayCountdown"] as? Number)?.toInt() ?: 10
    private val debug = (context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0

    private val methodChannel = MethodChannel(messenger, "dev.fredol.open_tv/exoplayer_$viewId")
    private val handler = Handler(Looper.getMainLooper())
    private val player: ExoPlayer
    private val playerView: PlayerView
    private val root: PlayerGestureLayout
    private val gestures: PlayerGestureController
    private val hasTouchscreen = context.packageManager.hasSystemFeature(PackageManager.FEATURE_TOUCHSCREEN)
    private val isTv = context.packageManager.hasSystemFeature(PackageManager.FEATURE_LEANBACK)
    // PiP is never used on Android TV, where Home should leave the player.
    val pipAllowed = (params["pictureInPicture"] as? Boolean ?: true) && !isTv
    private val appContext = context.applicationContext
    private val httpFactory: DefaultHttpDataSource.Factory
    val session: MediaSession

    private var zoomed = false
    private var reconnecting = false
    private var reconnectAttempts = 0
    private var switchingChannel = false
    private var pausedByPipClose = false
    private var sleepAtMs = 0L
    // Stop when the current movie or episode ends instead of after a delay.
    private var sleepAtEnd = false
    private var nextEpisode: Map<String, Any?>? = null
    private var countdownLeft = 0
    private var seekForward = true
    private var seekAccumulatedMs = 0L

    private val reconnectRunnable = Runnable {
        reconnecting = false
        player.setMediaItem(mediaItem())
        player.playWhenReady = true
        player.prepare()
    }
    private val sleepRunnable = Runnable { onSleepTimerFired() }
    private val hideChannelIndicator = Runnable { channelIndicator.visibility = View.GONE }
    private val hideSeekIndicators = Runnable {
        seekAccumulatedMs = 0L
        seekBackIndicator.visibility = View.GONE
        seekForwardIndicator.visibility = View.GONE
    }
    private val countdownTick = object : Runnable {
        override fun run() {
            countdownLeft--
            if (countdownLeft <= 0) {
                playNextEpisode()
            } else {
                updateCountdownLabel()
                handler.postDelayed(this, 1_000L)
            }
        }
    }
    private val channelIndicator: TextView
    private val nextOverlay: View
    private val nextLabel: TextView
    private val nextTitle: TextView
    private val nextPlayButton: View
    private val nextCancelButton: View
    private val seekBackIndicator: TextView
    private val seekForwardIndicator: TextView

    companion object {
        var active: ExoPlayerView? = null
        const val DIAG_TAG = "ExoPlayerDiag"
        const val CHANNEL_INDICATOR_MS = 2_000L
        const val SEEK_INDICATOR_MS = 800L
        val SLEEP_TIMER_MINUTES = intArrayOf(15, 30, 45, 60, 90, 120)
        val ACTIVE_TINT: Int = Color.parseColor("#FFC107")
        val RECONNECT_DELAYS_MS = longArrayOf(1_000L, 3_000L, 5_000L)
        const val BUFFER_MIN_MS = 30_000
        const val BUFFER_MAX_MS = 60_000
        const val BUFFER_FOR_PLAYBACK_MS = 10_000
        const val BUFFER_RESUME_AFTER_REBUFFER_MS = 10_000
        const val HTTP_CONNECT_TIMEOUT_MS = 15_000
        const val HTTP_READ_TIMEOUT_MS = 60_000
        // Android rejects PiP aspect ratios outside 1:2.39 .. 2.39:1.
        val PIP_MAX_RATIO = Rational(239, 100)
        val PIP_MIN_RATIO = Rational(100, 239)
    }

    init {
        methodChannel.setMethodCallHandler(this)
        httpFactory = createHttpFactory(params)
        player = ExoPlayer.Builder(context)
            .setMediaSourceFactory(
                DefaultMediaSourceFactory(context)
                    .setDataSourceFactory(httpFactory)
                    .setLoadErrorHandlingPolicy(DefaultLoadErrorHandlingPolicy(999))
            )
            .setLoadControl(tolerantLoadControl())
            .setSeekBackIncrementMs(seekIncrementMs)
            .setSeekForwardIncrementMs(seekIncrementMs)
            .build()
        root = LayoutInflater.from(context)
            .inflate(R.layout.exo_player_container, null) as PlayerGestureLayout
        root.keepScreenOn = true
        playerView = root.findViewById(R.id.player_view)
        gestures = PlayerGestureController(
            activity,
            root.findViewById(R.id.gesture_indicator),
            root.findViewById<ImageView>(R.id.gesture_indicator_icon),
            root.findViewById<ProgressBar>(R.id.gesture_indicator_level),
        )
        root.listener = gestures
        root.actionListener = this
        channelIndicator = root.findViewById(R.id.channel_indicator)
        seekBackIndicator = root.findViewById(R.id.seek_indicator_back)
        seekForwardIndicator = root.findViewById(R.id.seek_indicator_forward)
        nextOverlay = root.findViewById(R.id.next_episode_overlay)
        nextLabel = root.findViewById(R.id.next_episode_label)
        nextTitle = root.findViewById(R.id.next_episode_title)
        nextPlayButton = root.findViewById<View>(R.id.next_episode_play).apply {
            setOnClickListener { playNextEpisode() }
        }
        nextCancelButton = root.findViewById<View>(R.id.next_episode_cancel).apply {
            setOnClickListener { hideNextEpisode() }
        }
        updateGestureFlags(inPip = false)
        if (debug) player.addAnalyticsListener(EventLogger(DIAG_TAG))
        attachPlayer()
        bindControls()
        observeForReconnect()
        observeForPip()
        observePlayWhenReady()
        session = MediaSession.Builder(context, restrictedPlayer(player, blockedCommands(isLive)))
            .setId("exoplayer_$viewId")
            .setSessionActivity(openAppIntent())
            .build()
        active = this
        appContext.startService(Intent(appContext, PlaybackService::class.java))
        startPlayback()
    }

    private fun createHttpFactory(params: Map<String, Any?>): DefaultHttpDataSource.Factory =
        DefaultHttpDataSource.Factory()
            .setAllowCrossProtocolRedirects(true)
            .setConnectTimeoutMs(HTTP_CONNECT_TIMEOUT_MS)
            .setReadTimeoutMs(HTTP_READ_TIMEOUT_MS)
            .also { applyHeaders(it, params) }

    // Also used when switching channels; data sources created afterwards pick these up.
    private fun applyHeaders(factory: DefaultHttpDataSource.Factory, params: Map<String, Any?>) {
        val headers = HashMap<String, String>()
        (params["referer"] as? String)?.takeIf { it.isNotEmpty() }?.let { headers["Referer"] = it }
        (params["origin"] as? String)?.takeIf { it.isNotEmpty() }?.let { headers["Origin"] = it }
        factory.setDefaultRequestProperties(headers)
        factory.setUserAgent((params["userAgent"] as? String)?.takeIf { it.isNotEmpty() })
    }

    private fun attachPlayer() {
        playerView.player = restrictedPlayer(player, blockedCommands(isLive))
        playerView.setShowSubtitleButton(true)
        playerView.setShowNextButton(false)
        playerView.setShowPreviousButton(false)
        playerView.setShowBuffering(PlayerView.SHOW_BUFFERING_ALWAYS)
        playerView.controllerShowTimeoutMs = 1500
        playerView.isFocusable = true
        makeSeekBarGranular()
        syncControllerVisibility()
        if (isLive) hideLiveControls()
    }

    private fun makeSeekBarGranular() {
        val timeBar = playerView.findViewById<View?>(androidx.media3.ui.R.id.exo_progress) as? DefaultTimeBar
        timeBar?.setKeyTimeIncrement(seekIncrementMs)
    }

    private fun syncControllerVisibility() {
        val topBar = playerView.findViewById<View>(R.id.top_bar)
        playerView.setControllerVisibilityListener(
            PlayerView.ControllerVisibilityListener { visibility ->
                topBar.visibility = visibility
                if (isLive && visibility == View.VISIBLE) hideLiveControls()
            }
        )
    }

    private fun bindControls() {
        playerView.findViewById<TextView>(R.id.title_text).text = title
        playerView.findViewById<View>(R.id.back_button).setOnClickListener {
            methodChannel.invokeMethod("onBack", null)
        }
        playerView.findViewById<View>(R.id.audio_button).setOnClickListener { showAudioTrackDialog() }
        playerView.findViewById<View>(R.id.sleep_button).setOnClickListener { showSleepTimerDialog() }
        playerView.findViewById<View>(R.id.zoom_button).setOnClickListener { toggleZoom() }
    }

    private fun tolerantLoadControl(): LoadControl =
        DefaultLoadControl.Builder()
            .setBufferDurationsMs(
                BUFFER_MIN_MS,
                BUFFER_MAX_MS,
                BUFFER_FOR_PLAYBACK_MS,
                BUFFER_RESUME_AFTER_REBUFFER_MS,
            )
            .build()

    private fun observePlayWhenReady() {
        player.addListener(object : Player.Listener {
            override fun onPlaybackStateChanged(state: Int) {
                updateKeepScreenOn()
                if (state == Player.STATE_ENDED && !isLive) onMediaEnded()
            }

            override fun onPlayWhenReadyChanged(playWhenReady: Boolean, reason: Int) {
                updateKeepScreenOn()
                if (!isLive) return
                updateLiveControls()
                // A resumed live stream jumps back to the live edge instead of
                // playing from where it was paused.
                if (playWhenReady && reason == Player.PLAY_WHEN_READY_CHANGE_REASON_USER_REQUEST) {
                    player.seekToDefaultPosition()
                    if (player.playbackState == Player.STATE_IDLE || player.playbackState == Player.STATE_ENDED) {
                        player.prepare()
                    }
                }
            }
        })
    }

    // Let the screen turn off while paused or finished (e.g. after the sleep timer).
    private fun updateKeepScreenOn() {
        root.keepScreenOn = player.playWhenReady && player.playbackState != Player.STATE_ENDED
    }

    private fun onMediaEnded() {
        if (sleepAtEnd) {
            sleepAtEnd = false
            updateSleepButton()
            toast("Sleep timer: playback stopped")
            return
        }
        if (isEpisode && autoplayNext) requestNextEpisode()
    }

    // Asks Flutter for the episode after this one and offers it with a countdown.
    private fun requestNextEpisode() {
        val args = mapOf("position" to player.currentPosition, "duration" to player.duration)
        methodChannel.invokeMethod("nextEpisode", args, object : MethodChannel.Result {
            override fun success(result: Any?) {
                @Suppress("UNCHECKED_CAST")
                val next = result as? Map<String, Any?> ?: return
                if (player.playbackState != Player.STATE_ENDED) return
                showNextEpisode(next)
            }

            override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {}
            override fun notImplemented() {}
        })
    }

    private fun showNextEpisode(next: Map<String, Any?>) {
        nextEpisode = next
        nextTitle.text = next["title"] as? String ?: ""
        countdownLeft = autoplayCountdownSeconds
        updateCountdownLabel()
        nextOverlay.visibility = View.VISIBLE
        nextPlayButton.requestFocus()
        handler.removeCallbacks(countdownTick)
        handler.postDelayed(countdownTick, 1_000L)
    }

    private fun updateCountdownLabel() {
        nextLabel.text = "Next episode in $countdownLeft s"
    }

    private fun hideNextEpisode() {
        handler.removeCallbacks(countdownTick)
        nextOverlay.visibility = View.GONE
        nextEpisode = null
    }

    private fun playNextEpisode() {
        val next = nextEpisode ?: return
        hideNextEpisode()
        methodChannel.invokeMethod("playNext", null)
        loadChannel(next)
    }

    // While the next-episode overlay is shown, the remote moves between its buttons.
    private fun dispatchOverlayKey(event: KeyEvent): Boolean {
        when (event.keyCode) {
            KeyEvent.KEYCODE_DPAD_LEFT, KeyEvent.KEYCODE_DPAD_RIGHT -> {
                if (event.action == KeyEvent.ACTION_DOWN) {
                    (if (nextPlayButton.isFocused) nextCancelButton else nextPlayButton).requestFocus()
                }
            }
            KeyEvent.KEYCODE_DPAD_CENTER, KeyEvent.KEYCODE_ENTER, KeyEvent.KEYCODE_NUMPAD_ENTER -> {
                if (event.action == KeyEvent.ACTION_UP) {
                    (if (nextCancelButton.isFocused) nextCancelButton else nextPlayButton).performClick()
                }
            }
            KeyEvent.KEYCODE_DPAD_UP, KeyEvent.KEYCODE_DPAD_DOWN -> {}
            else -> return false
        }
        return true
    }

    private fun observeForReconnect() {
        player.addListener(object : Player.Listener {
            override fun onPlayerError(error: PlaybackException) {
                if (debug) Log.e(DIAG_TAG, "onPlayerError code=${error.errorCodeName} cause=${error.cause}", error)
                if (isLive) scheduleReconnect()
            }

            override fun onPlaybackStateChanged(state: Int) {
                if (debug) Log.i(DIAG_TAG, "onPlaybackStateChanged state=${stateName(state)}")
                when (state) {
                    Player.STATE_READY -> reconnectAttempts = 0
                    Player.STATE_ENDED -> if (isLive) scheduleReconnect()
                }
            }
        })
    }

    private fun stateName(state: Int): String = when (state) {
        Player.STATE_IDLE -> "IDLE"
        Player.STATE_BUFFERING -> "BUFFERING"
        Player.STATE_READY -> "READY"
        Player.STATE_ENDED -> "ENDED"
        else -> "UNKNOWN($state)"
    }

    private fun observeForPip() {
        player.addListener(object : Player.Listener {
            override fun onPlayWhenReadyChanged(playWhenReady: Boolean, reason: Int) = onPipStateChanged()
            override fun onVideoSizeChanged(videoSize: VideoSize) = onPipStateChanged()
        })
    }

    private fun openAppIntent(): PendingIntent {
        val intent = appContext.packageManager.getLaunchIntentForPackage(appContext.packageName)!!
            .setFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
        return PendingIntent.getActivity(appContext, 0, intent, PendingIntent.FLAG_IMMUTABLE)
    }

    private fun mediaItem(): MediaItem {
        val metadata = MediaMetadata.Builder()
            .setTitle(title)
            .apply { if (!image.isNullOrEmpty()) setArtworkUri(Uri.parse(image)) }
            .build()
        return MediaItem.Builder()
            .setUri(Uri.parse(url))
            .setMediaMetadata(metadata)
            .build()
    }

    val canEnterPip: Boolean get() = pipAllowed && player.playWhenReady

    fun pipAspectRatio(): Rational? {
        val size = player.videoSize
        if (size.width == 0 || size.height == 0) return null
        val ratio = Rational((size.width * size.pixelWidthHeightRatio).toInt(), size.height)
        return when {
            ratio > PIP_MAX_RATIO -> PIP_MAX_RATIO
            ratio < PIP_MIN_RATIO -> PIP_MIN_RATIO
            else -> ratio
        }
    }

    fun onPipModeChanged(inPip: Boolean) {
        if (inPip) playerView.hideController()
        playerView.useController = !inPip
        updateGestureFlags(inPip)
    }

    // The PiP window was dismissed (not expanded back to full screen).
    fun onPipClosed() {
        if (keepAudioAfterPip || !player.playWhenReady) return
        player.pause()
        pausedByPipClose = true
    }

    fun onHostResumed() {
        if (!pausedByPipClose) return
        pausedByPipClose = false
        // Live streams have no play button while playing, so resume them for the user.
        if (isLive) player.play()
    }

    private fun updateGestureFlags(inPip: Boolean) {
        val touch = hasTouchscreen && !inPip
        root.verticalDragsEnabled = touch && volumeBrightnessGestures
        root.horizontalSwipesEnabled = touch && swipeToChangeChannel && canSwitchChannel
        root.doubleTapsEnabled = touch && doubleTapSeek && !isLive
    }

    override fun onHorizontalSwipe(towardsLeft: Boolean) {
        requestChannelSwitch(if (towardsLeft) 1 else -1)
    }

    override fun onDoubleTap(leftSide: Boolean) {
        if (isLive) return
        val forward = !leftSide
        if (forward != seekForward) seekAccumulatedMs = 0L
        seekForward = forward
        if (forward) player.seekForward() else player.seekBack()
        seekAccumulatedMs += seekIncrementMs
        playerView.hideController()
        val seconds = seekAccumulatedMs / 1000
        val shown = if (forward) seekForwardIndicator else seekBackIndicator
        val hidden = if (forward) seekBackIndicator else seekForwardIndicator
        shown.text = if (forward) "+$seconds s" else "\u2212$seconds s"
        shown.visibility = View.VISIBLE
        hidden.visibility = View.GONE
        handler.removeCallbacks(hideSeekIndicators)
        handler.postDelayed(hideSeekIndicators, SEEK_INDICATOR_MS)
    }

    // Asks Flutter for the next (delta = 1) or previous (delta = -1) channel in
    // the list the player was opened from, then plays it.
    private fun requestChannelSwitch(delta: Int) {
        if (!canSwitchChannel || switchingChannel) return
        switchingChannel = true
        methodChannel.invokeMethod("switchChannel", delta, object : MethodChannel.Result {
            override fun success(result: Any?) {
                switchingChannel = false
                @Suppress("UNCHECKED_CAST")
                (result as? Map<String, Any?>)?.let { loadChannel(it) }
            }

            override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
                switchingChannel = false
            }

            override fun notImplemented() {
                switchingChannel = false
            }
        })
    }

    private fun loadChannel(params: Map<String, Any?>) {
        url = params["url"] as? String ?: return
        title = params["title"] as? String ?: ""
        image = params["image"] as? String
        applyHeaders(httpFactory, params)
        playerView.findViewById<TextView>(R.id.title_text).text = title
        handler.removeCallbacks(reconnectRunnable)
        reconnecting = false
        reconnectAttempts = 0
        hideNextEpisode()
        player.setMediaItem(mediaItem())
        val startMs = (params["startPositionMs"] as? Number)?.toLong() ?: 0L
        if (!isLive && startMs > 0) player.seekTo(startMs)
        player.playWhenReady = true
        player.prepare()
        channelIndicator.text = title
        channelIndicator.visibility = View.VISIBLE
        handler.removeCallbacks(hideChannelIndicator)
        handler.postDelayed(hideChannelIndicator, CHANNEL_INDICATOR_MS)
    }

    private fun showSleepTimerDialog() {
        val remainingMs = sleepAtMs - SystemClock.elapsedRealtime()
        val endLabel = if (isEpisode) "End of episode" else "End of movie"
        val dialogTitle = when {
            sleepAtEnd -> "Sleep timer (${endLabel.lowercase()})"
            sleepAtMs > 0 && remainingMs > 0 -> "Sleep timer (${(remainingMs + 59_999) / 60_000} min left)"
            else -> "Sleep timer"
        }
        val labels = listOf("Off") + SLEEP_TIMER_MINUTES.map { "$it minutes" } +
            (if (isLive) emptyList() else listOf(endLabel))
        AlertDialog.Builder(playerView.context, android.R.style.Theme_DeviceDefault_Dialog_Alert)
            .setTitle(dialogTitle)
            .setItems(labels.toTypedArray()) { dialog, which ->
                when {
                    which == 0 -> setSleepTimer(0)
                    which <= SLEEP_TIMER_MINUTES.size -> setSleepTimer(SLEEP_TIMER_MINUTES[which - 1])
                    else -> setSleepAtEnd()
                }
                dialog.dismiss()
            }
            .show()
    }

    private fun setSleepAtEnd() {
        handler.removeCallbacks(sleepRunnable)
        sleepAtMs = 0L
        sleepAtEnd = true
        toast(if (isEpisode) "Playback will stop after this episode" else "Playback will stop after this movie")
        updateSleepButton()
    }

    private fun setSleepTimer(minutes: Int) {
        handler.removeCallbacks(sleepRunnable)
        val wasSet = sleepAtMs > 0 || sleepAtEnd
        sleepAtEnd = false
        if (minutes > 0) {
            val delayMs = minutes * 60_000L
            sleepAtMs = SystemClock.elapsedRealtime() + delayMs
            handler.postDelayed(sleepRunnable, delayMs)
            toast("Playback will stop in $minutes minutes")
        } else {
            if (wasSet) toast("Sleep timer off")
            sleepAtMs = 0L
        }
        updateSleepButton()
    }

    private fun onSleepTimerFired() {
        sleepAtMs = 0L
        hideNextEpisode()
        player.pause()
        updateSleepButton()
        toast("Sleep timer: playback stopped")
    }

    private fun updateSleepButton() {
        val button = playerView.findViewById<ImageView?>(R.id.sleep_button) ?: return
        val active = sleepAtMs > 0 || sleepAtEnd
        button.imageTintList = ColorStateList.valueOf(if (active) ACTIVE_TINT else Color.WHITE)
    }

    private fun toast(message: String) {
        Toast.makeText(appContext, message, Toast.LENGTH_SHORT).show()
    }

    private fun startPlayback() {
        player.setMediaItem(mediaItem())
        if (!isLive && startPositionMs > 0) player.seekTo(startPositionMs)
        player.playWhenReady = true
        player.prepare()
    }

    private fun restrictedPlayer(delegate: Player, blocked: IntArray): Player {
        return object : ForwardingPlayer(delegate) {
            override fun getAvailableCommands(): Player.Commands {
                val builder = super.getAvailableCommands().buildUpon()
                for (command in blocked) builder.remove(command)
                return builder.build()
            }

            override fun isCommandAvailable(command: Int): Boolean =
                command !in blocked && super.isCommandAvailable(command)
        }
    }

    // Live streams keep play/pause so they can be stopped (notification, sleep
    // timer) and resumed; the button is only shown while paused.
    private fun blockedCommands(isLive: Boolean): IntArray {
        val blocked = mutableListOf(Player.COMMAND_SET_SPEED_AND_PITCH)
        if (isLive) {
            blocked += listOf(
                Player.COMMAND_SEEK_BACK,
                Player.COMMAND_SEEK_FORWARD,
                Player.COMMAND_SEEK_IN_CURRENT_MEDIA_ITEM,
                Player.COMMAND_SEEK_TO_PREVIOUS,
                Player.COMMAND_SEEK_TO_NEXT,
                Player.COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM,
                Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM,
            )
        }
        return blocked.toIntArray()
    }

    private fun hideLiveControls() {
        intArrayOf(
            androidx.media3.ui.R.id.exo_progress,
            androidx.media3.ui.R.id.exo_time,
            androidx.media3.ui.R.id.exo_rew_with_amount,
            androidx.media3.ui.R.id.exo_ffwd_with_amount,
        ).forEach { id -> playerView.findViewById<View?>(id)?.visibility = View.GONE }
        updateLiveControls()
    }

    private fun updateLiveControls() {
        playerView.findViewById<View?>(androidx.media3.ui.R.id.exo_play_pause)?.visibility =
            if (player.playWhenReady) View.GONE else View.VISIBLE
    }

    private fun showAudioTrackDialog() {
        val activePlayer = playerView.player ?: return
        val groups = activePlayer.currentTracks.groups.filter { it.type == C.TRACK_TYPE_AUDIO }
        if (groups.isEmpty()) return

        val labels = mutableListOf("Auto")
        val overrides = mutableListOf<TrackSelectionOverride?>(null)
        for (group in groups) {
            for (i in 0 until group.length) {
                if (!group.isTrackSupported(i)) continue
                val prefix = if (group.isTrackSelected(i)) "✓ " else ""
                labels.add(prefix + audioTrackLabel(group.getTrackFormat(i), overrides.size))
                overrides.add(TrackSelectionOverride(group.mediaTrackGroup, i))
            }
        }

        AlertDialog.Builder(playerView.context, android.R.style.Theme_DeviceDefault_Dialog_Alert)
            .setTitle(R.string.exo_audio)
            .setItems(labels.toTypedArray()) { dialog, which ->
                val params = activePlayer.trackSelectionParameters.buildUpon()
                    .clearOverridesOfType(C.TRACK_TYPE_AUDIO)
                    .setTrackTypeDisabled(C.TRACK_TYPE_AUDIO, false)
                overrides[which]?.let { params.addOverride(it) }
                activePlayer.trackSelectionParameters = params.build()
                dialog.dismiss()
            }
            .show()
    }

    private fun audioTrackLabel(format: Format, fallbackIndex: Int): String {
        format.label?.let { return it }
        val lang = format.language
        if (!lang.isNullOrEmpty() && lang != "und") {
            val display = Locale(lang).displayLanguage
            return if (display.isNotEmpty()) display else lang
        }
        return when (format.channelCount) {
            1 -> "Mono"
            2 -> "Stereo"
            6 -> "5.1"
            8 -> "7.1"
            Format.NO_VALUE -> "Audio $fallbackIndex"
            else -> "${format.channelCount} channels"
        }
    }

    private fun toggleZoom() {
        zoomed = !zoomed
        playerView.resizeMode = if (zoomed) {
            AspectRatioFrameLayout.RESIZE_MODE_ZOOM
        } else {
            AspectRatioFrameLayout.RESIZE_MODE_FIT
        }
    }

    fun dispatchDpad(event: KeyEvent): Boolean {
        val keyCode = event.keyCode
        if (nextOverlay.visibility == View.VISIBLE && dispatchOverlayKey(event)) return true
        if (canSwitchChannel) {
            val delta = channelKeyDelta(keyCode)
            if (delta != 0) {
                if (event.action == KeyEvent.ACTION_DOWN && event.repeatCount == 0) {
                    requestChannelSwitch(delta)
                }
                return true
            }
        }
        if (!isNavOrSelect(keyCode)) return false

        if (controlsNeedWaking()) {
            if (event.action == KeyEvent.ACTION_DOWN) wakeControls()
            return true
        }

        val focused = root.findFocus()!!
        if (focused.dispatchKeyEvent(event)) {
            playerView.showController()
            return true
        }
        if (event.action == KeyEvent.ACTION_DOWN && isDirection(keyCode)) {
            moveFocus(focused, keyCode)
        }
        return true
    }

    // Channel keys always switch; D-pad up/down only while the controls are hidden
    // (otherwise they move focus between the controls).
    private fun channelKeyDelta(keyCode: Int): Int = when (keyCode) {
        KeyEvent.KEYCODE_CHANNEL_UP, KeyEvent.KEYCODE_PAGE_UP -> -1
        KeyEvent.KEYCODE_CHANNEL_DOWN, KeyEvent.KEYCODE_PAGE_DOWN -> 1
        KeyEvent.KEYCODE_DPAD_UP -> if (controlsNeedWaking()) -1 else 0
        KeyEvent.KEYCODE_DPAD_DOWN -> if (controlsNeedWaking()) 1 else 0
        else -> 0
    }

    private fun controlsNeedWaking(): Boolean =
        !playerView.isControllerFullyVisible || root.findFocus() == null

    private fun wakeControls() {
        playerView.showController()
        focusDefaultControl()
    }

    private fun moveFocus(from: View, keyCode: Int) {
        val direction = directionFor(keyCode)
        from.focusSearch(direction)?.requestFocus(direction)
        playerView.showController()
    }

    private fun focusDefaultControl() {
        val candidates = listOfNotNull(
            playerView.findViewById<View?>(androidx.media3.ui.R.id.exo_play_pause),
            playerView.findViewById<View?>(R.id.sleep_button),
            playerView.findViewById<View?>(R.id.audio_button),
            playerView.findViewById<View?>(R.id.zoom_button),
        )
        candidates.firstOrNull { it.isShown }?.requestFocus()
    }

    private fun isNavOrSelect(keyCode: Int): Boolean =
        isDirection(keyCode) ||
            keyCode == KeyEvent.KEYCODE_DPAD_CENTER ||
            keyCode == KeyEvent.KEYCODE_ENTER ||
            keyCode == KeyEvent.KEYCODE_NUMPAD_ENTER

    private fun isDirection(keyCode: Int): Boolean =
        keyCode == KeyEvent.KEYCODE_DPAD_UP ||
            keyCode == KeyEvent.KEYCODE_DPAD_DOWN ||
            keyCode == KeyEvent.KEYCODE_DPAD_LEFT ||
            keyCode == KeyEvent.KEYCODE_DPAD_RIGHT

    private fun directionFor(keyCode: Int): Int = when (keyCode) {
        KeyEvent.KEYCODE_DPAD_UP -> View.FOCUS_UP
        KeyEvent.KEYCODE_DPAD_DOWN -> View.FOCUS_DOWN
        KeyEvent.KEYCODE_DPAD_LEFT -> View.FOCUS_LEFT
        else -> View.FOCUS_RIGHT
    }

    private fun scheduleReconnect() {
        if (reconnecting) return
        reconnecting = true
        val delay = RECONNECT_DELAYS_MS[reconnectAttempts.coerceAtMost(RECONNECT_DELAYS_MS.lastIndex)]
        if (debug) Log.w(DIAG_TAG, "scheduleReconnect attempt=$reconnectAttempts delayMs=$delay")
        reconnectAttempts++
        handler.postDelayed(reconnectRunnable, delay)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getPosition" -> result.success(player.currentPosition)
            "getDuration" -> result.success(player.duration.takeIf { it != C.TIME_UNSET } ?: 0L)
            else -> result.notImplemented()
        }
    }

    override fun getView(): View = root

    override fun dispose() {
        val wasActive = active === this
        if (wasActive) active = null
        methodChannel.setMethodCallHandler(null)
        handler.removeCallbacksAndMessages(null)
        gestures.release()
        session.release()
        if (wasActive) {
            appContext.stopService(Intent(appContext, PlaybackService::class.java))
            onPipStateChanged()
        }
        playerView.player = null
        player.release()
    }
}
