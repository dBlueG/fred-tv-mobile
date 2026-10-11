package dev.fredol.open_tv

import android.app.Activity
import android.content.Context
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

class ExoPlayerViewFactory(
    private val activity: Activity,
    private val messenger: BinaryMessenger,
    private val onPipStateChanged: () -> Unit,
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        @Suppress("UNCHECKED_CAST")
        val params = (args as? Map<String, Any?>) ?: emptyMap()
        return ExoPlayerView(activity, context, messenger, viewId, params, onPipStateChanged)
    }
}
