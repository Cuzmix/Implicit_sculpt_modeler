/*
 * libmain.so's entry and the C library pieces Android lacks. SDLActivity loads
 * libSDL3.so and libmain.so, then calls SDL_main on a thread of its own; the Odin
 * object (src/app built with -build-mode:obj) defines the C main that starts Odin's
 * runtime and runs the app. Below them, asking Android for the screen's frame rate.
 */

#include <dlfcn.h>
#include <jni.h>
#include <stdint.h>
#include <android/log.h>
#include <android/native_window.h>
#include <SDL3/SDL_system.h>

extern int main(int argc, char *argv[]);

__attribute__((visibility("default"))) int SDL_main(int argc, char *argv[])
{
	return main(argc, argv);
}

/*
 * Odin's core:thread lets every thread it starts be cancelled; bionic has no thread
 * cancellation and so neither of these. Nothing in the app cancels a thread, so they
 * only report success.
 */
int pthread_setcancelstate(int state, int *old_state)
{
	(void)state;
	if (old_state) *old_state = 0;
	return 0;
}

int pthread_setcanceltype(int type, int *old_type)
{
	(void)type;
	if (old_type) *old_type = 0;
	return 0;
}

/*
 * The screen's frame rate (src/app/frame_rate.odin). Android runs an app's screen at
 * 60 Hz unless the app asks for more, even on a 120 Hz tablet, and SDL never asks. The
 * highest rate the screen offers comes from Display.getSupportedModes() through JNI, at
 * the screen's current resolution (a mode of another resolution would resize the
 * surface). Returns that rate, 0 when JNI cannot tell, and leaves no exception pending.
 */
static float display_top_rate(void)
{
	JNIEnv *env = (JNIEnv *)SDL_GetAndroidJNIEnv();
	if (!env) return 0;
	jobject activity = (jobject)SDL_GetAndroidActivity();
	if (!activity) return 0;
	float top = 0;
	if ((*env)->PushLocalFrame(env, 32) == 0) {
		jclass activity_class = (*env)->GetObjectClass(env, activity);
		jmethodID get_wm = (*env)->GetMethodID(env, activity_class, "getWindowManager", "()Landroid/view/WindowManager;");
		jobject wm = get_wm ? (*env)->CallObjectMethod(env, activity, get_wm) : NULL;
		jobject display = NULL;
		if (wm && !(*env)->ExceptionCheck(env)) {
			jmethodID get_display = (*env)->GetMethodID(env, (*env)->GetObjectClass(env, wm), "getDefaultDisplay", "()Landroid/view/Display;");
			if (get_display) display = (*env)->CallObjectMethod(env, wm, get_display);
		}
		jclass display_class = display && !(*env)->ExceptionCheck(env) ? (*env)->FindClass(env, "android/view/Display") : NULL;
		jclass mode_class = display_class ? (*env)->FindClass(env, "android/view/Display$Mode") : NULL;
		jmethodID get_mode = mode_class ? (*env)->GetMethodID(env, display_class, "getMode", "()Landroid/view/Display$Mode;") : NULL;
		jmethodID get_modes = mode_class ? (*env)->GetMethodID(env, display_class, "getSupportedModes", "()[Landroid/view/Display$Mode;") : NULL;
		jmethodID width_of = mode_class ? (*env)->GetMethodID(env, mode_class, "getPhysicalWidth", "()I") : NULL;
		jmethodID height_of = mode_class ? (*env)->GetMethodID(env, mode_class, "getPhysicalHeight", "()I") : NULL;
		jmethodID rate_of = mode_class ? (*env)->GetMethodID(env, mode_class, "getRefreshRate", "()F") : NULL;
		if (get_mode && get_modes && width_of && height_of && rate_of) {
			jobject current = (*env)->CallObjectMethod(env, display, get_mode);
			jobjectArray modes = (jobjectArray)(*env)->CallObjectMethod(env, display, get_modes);
			if (current && modes && !(*env)->ExceptionCheck(env)) {
				jint w = (*env)->CallIntMethod(env, current, width_of);
				jint h = (*env)->CallIntMethod(env, current, height_of);
				top = (*env)->CallFloatMethod(env, current, rate_of);
				jsize n = (*env)->GetArrayLength(env, modes);
				for (jsize i = 0; i < n && !(*env)->ExceptionCheck(env); i++) {
					jobject mode = (*env)->GetObjectArrayElement(env, modes, i);
					if (!mode) continue;
					if ((*env)->CallIntMethod(env, mode, width_of) == w && (*env)->CallIntMethod(env, mode, height_of) == h) {
						float rate = (*env)->CallFloatMethod(env, mode, rate_of);
						if (rate > top) top = rate;
					}
					(*env)->DeleteLocalRef(env, mode);
				}
			}
		}
		if ((*env)->ExceptionCheck(env)) {
			(*env)->ExceptionClear(env);
			top = 0;
		}
		(*env)->PopLocalFrame(env, NULL);
	}
	(*env)->DeleteLocalRef(env, activity);
	return top;
}

/*
 * Asks Android to run the screen at `rate` Hz for this window, or at the highest rate it
 * offers when `rate` is 0, and returns that highest rate (0: unknown). Android 12 and
 * later may switch the mode even where the switch is not seamless when the highest rate is
 * asked for: it happens once, when the app opens. A vote belongs to the surface, so the
 * app asks again whenever its surface is new.
 */
typedef int32_t (*Set_Frame_Rate_Strategy)(ANativeWindow *, float, int8_t, int8_t);

float sculpt_android_frame_rate(void *native_window, float rate)
{
	static float top = -1;
	if (top < 0) top = display_top_rate();
	ANativeWindow *window = (ANativeWindow *)native_window;
	if (!window) return top;
	float wanted = rate > 0 ? rate : top;
	if (wanted <= 0) return top;
	static Set_Frame_Rate_Strategy with_strategy = NULL;
	static int looked = 0;
	if (!looked) {
		looked = 1;
		void *lib = dlopen("libandroid.so", RTLD_NOW);
		if (lib) with_strategy = (Set_Frame_Rate_Strategy)dlsym(lib, "ANativeWindow_setFrameRateWithChangeStrategy");
	}
	int32_t err;
	if (with_strategy) {
		/* ANATIVEWINDOW_CHANGE_FRAME_RATE_ALWAYS is 1, ONLY_IF_SEAMLESS 0. */
		err = with_strategy(window, wanted, ANATIVEWINDOW_FRAME_RATE_COMPATIBILITY_DEFAULT, rate > 0 ? 0 : 1);
	} else {
		err = ANativeWindow_setFrameRate(window, wanted, ANATIVEWINDOW_FRAME_RATE_COMPATIBILITY_DEFAULT);
	}
	if (err != 0) __android_log_print(ANDROID_LOG_WARN, "sculpt", "ANativeWindow_setFrameRate(%.0f) failed: %d", wanted, err);
	return top;
}
