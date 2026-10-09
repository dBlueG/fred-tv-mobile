package dev.fredol.open_tv

import android.app.PictureInPictureParams
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.os.Build
import android.view.KeyEvent
import androidx.annotation.RequiresApi
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        flutterEngine.platformViewsController.registry.registerViewFactory(
            "dev.fredol.open_tv/exoplayer",
            ExoPlayerViewFactory(flutterEngine.dartExecutor.binaryMessenger, ::updatePipParams),
        )
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (ExoPlayerView.active?.dispatchDpad(event) == true) {
            return true
        }
        return super.dispatchKeyEvent(event)
    }

    // Android 12+ enters PiP on its own via setAutoEnterEnabled; older versions need this.
    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (Build.VERSION.SDK_INT in Build.VERSION_CODES.O until Build.VERSION_CODES.S &&
            supportsPip() && ExoPlayerView.active?.wantsPlayback == true
        ) {
            enterPictureInPictureMode(pipParams())
        }
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: Configuration) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        ExoPlayerView.active?.onPipModeChanged(isInPictureInPictureMode)
    }

    private fun updatePipParams() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O || !supportsPip()) return
        setPictureInPictureParams(pipParams())
    }

    @RequiresApi(Build.VERSION_CODES.O)
    private fun pipParams(): PictureInPictureParams {
        val view = ExoPlayerView.active
        val builder = PictureInPictureParams.Builder()
        view?.pipAspectRatio()?.let { builder.setAspectRatio(it) }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.setAutoEnterEnabled(view?.wantsPlayback == true)
        }
        return builder.build()
    }

    private fun supportsPip(): Boolean =
        packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)
}
