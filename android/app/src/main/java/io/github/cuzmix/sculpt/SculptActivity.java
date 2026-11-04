package io.github.cuzmix.sculpt;

import android.graphics.Rect;
import android.view.MotionEvent;
import android.view.View;

import java.util.ArrayList;
import java.util.List;

import org.libsdl.app.SDLActivity;

/**
 * SDL's activity, plus what SDL 3.4's Java side leaves out of a stylus: its lean and its
 * samples between frames. SDL reads a stylus's position, pressure, buttons and eraser, but
 * not its AXIS_TILT or AXIS_ORIENTATION, so a Tilt brush never leans on an Android tablet;
 * and it reads only a MotionEvent's newest sample, while Android batches the pen's samples
 * of a frame into one event's history, so a fast stroke arrived as one point a frame. Every
 * touch and hover event passes here before SDL's view sees it; for a stylus or its eraser,
 * the lean and the older samples go to libmain.so (android/app/jni/android_main.c), which
 * hands them to the app as SDL events ahead of the pen's own, and SDL then handles the
 * event as before. It also keeps the strips of the side edges where a dock stands from
 * Android's back gesture (setGestureExclusion).
 */
public class SculptActivity extends SDLActivity {
    /** The stylus's AXIS_TILT and AXIS_ORIENTATION, in radians. */
    private static native void nativePenLean(float tilt, float orientation);

    /**
     * One of the stylus's older samples in this event: where it was from the event's own
     * (newest) sample, in the event's pixels, its pressure, and its AXIS_TILT and
     * AXIS_ORIENTATION in radians (src/app/pen_samples.odin).
     */
    private static native void nativePenSample(float dx, float dy, float pressure, float tilt, float orientation);

    private static void lean(MotionEvent event) {
        // Until libmain.so has loaded, which SDLActivity says through mBrokenLibraries, the
        // native methods do not exist yet.
        if (mBrokenLibraries) {
            return;
        }
        for (int i = 0; i < event.getPointerCount(); i++) {
            int tool = event.getToolType(i);
            if (tool == MotionEvent.TOOL_TYPE_STYLUS || tool == MotionEvent.TOOL_TYPE_ERASER) {
                // The older samples of a move first, oldest first: SDL reports the newest.
                if (event.getActionMasked() == MotionEvent.ACTION_MOVE) {
                    float x = event.getX(i), y = event.getY(i);
                    for (int h = 0; h < event.getHistorySize(); h++) {
                        nativePenSample(event.getHistoricalX(i, h) - x, event.getHistoricalY(i, h) - y,
                                Math.min(event.getHistoricalPressure(i, h), 1.0f),
                                event.getHistoricalAxisValue(MotionEvent.AXIS_TILT, i, h),
                                event.getHistoricalAxisValue(MotionEvent.AXIS_ORIENTATION, i, h));
                    }
                }
                nativePenLean(event.getAxisValue(MotionEvent.AXIS_TILT, i), event.getAxisValue(MotionEvent.AXIS_ORIENTATION, i));
                return;
            }
        }
    }

    @Override
    public boolean dispatchTouchEvent(MotionEvent event) {
        lean(event);
        return super.dispatchTouchEvent(event);
    }

    @Override
    public boolean dispatchGenericMotionEvent(MotionEvent event) {
        lean(event);
        return super.dispatchGenericMotionEvent(event);
    }

    /**
     * The strips of the side edges the app keeps from the system's back gesture, so a drag
     * that starts on a dock standing on a side edge is the app's: `rects` holds left, top,
     * right and bottom in the window's pixels for each, from libmain.so on the app's thread
     * (src/app/gesture_edges.odin). Android keeps at most 200 dp of each edge's height for
     * an app, the lowest first.
     */
    public void setGestureExclusion(int[] rects) {
        final List<Rect> list = new ArrayList<>();
        for (int i = 0; i + 3 < rects.length; i += 4) {
            list.add(new Rect(rects[i], rects[i + 1], rects[i + 2], rects[i + 3]));
        }
        runOnUiThread(() -> {
            View view = getWindow().getDecorView();
            view.setSystemGestureExclusionRects(list);
        });
    }
}
