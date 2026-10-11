package dev.fredol.open_tv

import android.content.Context
import android.util.AttributeSet
import android.view.MotionEvent
import android.view.ViewConfiguration
import android.widget.FrameLayout
import kotlin.math.abs

// Container that claims vertical drags from its children (taps, buttons and the
// seek bar keep working) and reports them as fractions of its height.
class PlayerGestureLayout @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
) : FrameLayout(context, attrs) {

    interface Listener {
        // Returns false to ignore the drag.
        fun onVerticalDragStart(leftSide: Boolean): Boolean
        // Positive when moving up; 1.0 equals the full height of the layout.
        fun onVerticalDrag(delta: Float)
        fun onVerticalDragEnd()
    }

    companion object {
        // Drags starting this close to the top/bottom edge are left to the system.
        const val EDGE_FRACTION = 0.08f
        // How much more vertical than horizontal a move must be to count.
        const val VERTICAL_BIAS = 1.5f
    }

    var listener: Listener? = null
    var gesturesEnabled = true

    private val touchSlop = ViewConfiguration.get(context).scaledTouchSlop
    private var downX = 0f
    private var downY = 0f
    private var lastY = 0f
    private var tracking = false
    private var dragging = false

    override fun onInterceptTouchEvent(ev: MotionEvent): Boolean {
        handle(ev)
        return dragging
    }

    override fun onTouchEvent(ev: MotionEvent): Boolean {
        handle(ev)
        return tracking || dragging
    }

    private fun handle(ev: MotionEvent) {
        when (ev.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                downX = ev.x
                downY = ev.y
                lastY = ev.y
                dragging = false
                tracking = gesturesEnabled && listener != null && height > 0 && !inEdgeZone(ev.y)
            }
            MotionEvent.ACTION_POINTER_DOWN -> stop()
            MotionEvent.ACTION_MOVE -> when {
                dragging -> {
                    listener?.onVerticalDrag((lastY - ev.y) / height)
                    lastY = ev.y
                }
                tracking -> detectDrag(ev)
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> stop()
        }
    }

    private fun detectDrag(ev: MotionEvent) {
        val dx = abs(ev.x - downX)
        val dy = abs(ev.y - downY)
        if (dy > touchSlop && dy > dx * VERTICAL_BIAS) {
            dragging = listener?.onVerticalDragStart(downX < width / 2f) == true
            tracking = dragging
            if (dragging) {
                lastY = ev.y
                parent?.requestDisallowInterceptTouchEvent(true)
            }
        } else if (dx > touchSlop) {
            tracking = false
        }
    }

    private fun stop() {
        if (dragging) listener?.onVerticalDragEnd()
        dragging = false
        tracking = false
    }

    private fun inEdgeZone(y: Float): Boolean =
        y < height * EDGE_FRACTION || y > height * (1 - EDGE_FRACTION)
}
