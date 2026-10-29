package io.github.cuzmix.sculpt;

import android.view.MotionEvent;

import org.libsdl.app.SDLActivity;

/**
 * SDL's activity, plus the pen's lean. SDL 3.4's Java side reads a stylus's position,
 * pressure, buttons and eraser, but not its AXIS_TILT or AXIS_ORIENTATION, so a Tilt brush
 * never leans on an Android tablet. Every touch and hover event passes here before SDL's
 * view sees it; for a stylus or its eraser, the lean goes to libmain.so
 * (android/app/jni/android_main.c), which hands it to the app as an SDL event ahead of the
 * pen's own, and SDL then handles the event as before.
 */
public class SculptActivity extends SDLActivity {
    /** The stylus's AXIS_TILT and AXIS_ORIENTATION, in radians. */
    private static native void nativePenLean(float tilt, float orientation);

    private static void lean(MotionEvent event) {
        // Until libmain.so has loaded, which SDLActivity says through mBrokenLibraries, the
        // native method does not exist yet.
        if (mBrokenLibraries) {
            return;
        }
        for (int i = 0; i < event.getPointerCount(); i++) {
            int tool = event.getToolType(i);
            if (tool == MotionEvent.TOOL_TYPE_STYLUS || tool == MotionEvent.TOOL_TYPE_ERASER) {
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
}
