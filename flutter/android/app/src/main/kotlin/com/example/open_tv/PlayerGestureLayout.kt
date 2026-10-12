package dev.fredol.open_tv

import android.content.Context
import android.util.AttributeSet
import android.view.MotionEvent
import android.view.ViewConfiguration
import android.widget.FrameLayout
import kotlin.math.abs
import kotlin.math.hypot

// Container that claims vertical drags, horizontal swipes and double taps from
// its children (single taps, buttons and the seek bar keep working). Vertical
// drags are reported as fractions of its height.
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

    interface ActionListener {
        fun onHorizontalSwipe(towardsLeft: Boolean)
        fun onDoubleTap(leftSide: Boolean)
    }

    companion object {
        // Drags starting this close to the top/bottom edge are left to the system.
        const val EDGE_FRACTION = 0.08f
        // How much more vertical than horizontal a move must be to count, and vice versa.
        const val DIRECTION_BIAS = 1.5f
        // A horizontal swipe must cover this fraction of the width.
        const val SWIPE_FRACTION = 0.15f
        // Double taps in the middle of the screen, and over the top bar or the
        // seek bar and buttons at the bottom, are left to the controls.
        const val DOUBLE_TAP_SIDE_FRACTION = 0.4f
        const val DOUBLE_TAP_TOP_FRACTION = 0.15f
        const val DOUBLE_TAP_BOTTOM_FRACTION = 0.25f
    }

    var listener: Listener? = null
    var actionListener: ActionListener? = null
    var verticalDragsEnabled = true
    var horizontalSwipesEnabled = false
    var doubleTapsEnabled = false

    private val config = ViewConfiguration.get(context)
    private val touchSlop = config.scaledTouchSlop
    private val doubleTapSlop = config.scaledDoubleTapSlop
    private val doubleTapTimeout = ViewConfiguration.getDoubleTapTimeout().toLong()
    private val tapTimeout = ViewConfiguration.getLongPressTimeout().toLong()

    private var downX = 0f
    private var downY = 0f
    private var downTime = 0L
    private var lastY = 0f
    private var tracking = false
    private var dragging = false
    private var swiping = false
    private var consumingTap = false
    private var moved = false
    private var lastTapUpTime = 0L
    private var lastTapX = 0f
    private var lastTapY = 0f
    private var lastEventTime = -1L
    private var lastEventAction = -1

    override fun onInterceptTouchEvent(ev: MotionEvent): Boolean {
        handle(ev)
        return dragging || swiping || consumingTap
    }

    override fun onTouchEvent(ev: MotionEvent): Boolean {
        handle(ev)
        return tracking || dragging || swiping || consumingTap
    }

    private fun handle(ev: MotionEvent) {
        // An intercepted event is also delivered to onTouchEvent; handle it once.
        if (ev.eventTime == lastEventTime && ev.actionMasked == lastEventAction) return
        lastEventTime = ev.eventTime
        lastEventAction = ev.actionMasked
        when (ev.actionMasked) {
            MotionEvent.ACTION_DOWN -> onDown(ev)
            MotionEvent.ACTION_POINTER_DOWN -> stop(null)
            MotionEvent.ACTION_MOVE -> {
                if (!moved && hypot(ev.x - downX, ev.y - downY) > touchSlop) moved = true
                when {
                    dragging -> {
                        listener?.onVerticalDrag((lastY - ev.y) / height)
                        lastY = ev.y
                    }
                    tracking -> detectDrag(ev)
                }
            }
            MotionEvent.ACTION_UP -> stop(ev)
            MotionEvent.ACTION_CANCEL -> stop(null)
        }
    }

    private fun onDown(ev: MotionEvent) {
        downX = ev.x
        downY = ev.y
        downTime = ev.eventTime
        lastY = ev.y
        dragging = false
        swiping = false
        moved = false
        consumingTap = isSecondTap(ev)
        if (consumingTap) {
            actionListener?.onDoubleTap(ev.x < width / 2f)
            tracking = false
            return
        }
        tracking = (verticalDragsEnabled && listener != null || horizontalSwipesEnabled) &&
            height > 0 && !inEdgeZone(ev.y)
    }

    private fun isSecondTap(ev: MotionEvent): Boolean {
        if (!doubleTapsEnabled || actionListener == null || width == 0) return false
        if (ev.eventTime - lastTapUpTime > doubleTapTimeout) return false
        if (hypot(ev.x - lastTapX, ev.y - lastTapY) > doubleTapSlop) return false
        if (ev.y < height * DOUBLE_TAP_TOP_FRACTION || ev.y > height * (1 - DOUBLE_TAP_BOTTOM_FRACTION)) return false
        return ev.x < width * DOUBLE_TAP_SIDE_FRACTION || ev.x > width * (1 - DOUBLE_TAP_SIDE_FRACTION)
    }

    private fun detectDrag(ev: MotionEvent) {
        val dx = abs(ev.x - downX)
        val dy = abs(ev.y - downY)
        if (verticalDragsEnabled && dy > touchSlop && dy > dx * DIRECTION_BIAS) {
            dragging = listener?.onVerticalDragStart(downX < width / 2f) == true
            tracking = dragging
            if (dragging) {
                lastY = ev.y
                parent?.requestDisallowInterceptTouchEvent(true)
            }
        } else if (horizontalSwipesEnabled && dx > touchSlop && dx > dy * DIRECTION_BIAS) {
            swiping = true
            tracking = false
            parent?.requestDisallowInterceptTouchEvent(true)
        } else if (dx > touchSlop || dy > touchSlop) {
            tracking = false
        }
    }

    private fun stop(up: MotionEvent?) {
        if (dragging) listener?.onVerticalDragEnd()
        if (swiping && up != null && abs(up.x - downX) > width * SWIPE_FRACTION) {
            actionListener?.onHorizontalSwipe(up.x < downX)
        }
        // Remember plain taps (including consumed ones, so repeated taps keep seeking).
        if (up != null && !moved && up.eventTime - downTime < tapTimeout) {
            lastTapUpTime = up.eventTime
            lastTapX = up.x
            lastTapY = up.y
        } else {
            lastTapUpTime = 0L
        }
        dragging = false
        swiping = false
        tracking = false
        consumingTap = false
    }

    private fun inEdgeZone(y: Float): Boolean =
        y < height * EDGE_FRACTION || y > height * (1 - EDGE_FRACTION)
}
