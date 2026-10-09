package dev.fredol.open_tv

import android.content.Intent
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService

// Hosts the active ExoPlayerView's MediaSession so Media3 can post the media
// notification and keep the process in the foreground while audio plays.
class PlaybackService : MediaSessionService() {
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val result = super.onStartCommand(intent, flags, startId)
        ExoPlayerView.active?.session?.let { if (!isSessionAdded(it)) addSession(it) }
        return result
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession? =
        ExoPlayerView.active?.session

    override fun onTaskRemoved(rootIntent: Intent?) {
        ExoPlayerView.active?.session?.player?.pause()
        stopSelf()
    }
}
