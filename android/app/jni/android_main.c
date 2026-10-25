/*
 * libmain.so's entry and the C library pieces Android lacks. SDLActivity loads
 * libSDL3.so and libmain.so, then calls SDL_main on a thread of its own; the Odin
 * object (src/app built with -build-mode:obj) defines the C main that starts Odin's
 * runtime and runs the app.
 */

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
