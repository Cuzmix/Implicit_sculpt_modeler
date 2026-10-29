/*
 * The iPad app's native pieces that SDL lacks. SDL 3.4 has file dialogs on Android, macOS,
 * Windows and Linux but none on iOS, so the three dialogs below stand in for
 * SDL_ShowOpenFileDialog, SDL_ShowSaveFileDialog and SDL_ShowOpenFolderDialog
 * (src/app/ios.odin, files.odin) and answer through the same SDL_DialogFileCallback: a list
 * of one path, an empty list for a cancel, NULL after SDL_SetError for a failure. The frame
 * loop calls them on the main thread; UIKit answers on it too, while SDL pumps events.
 *
 * iOS has no "save as" picker that names a new file, so a save asks for the name first,
 * then for the folder it goes in (starting in the app's own Documents folder, which Files
 * shows as On My iPad > Sculpt), and the app writes there itself.
 *
 * The Apple Pencil's double-tap, squeeze, Pencil-only drawing and haptics follow, then the
 * Pencil's samples between frames, and at the end Scribble for the app's text fields.
 *
 * Built with ARC (-fobjc-arc) by `./build.sh ios`.
 */

#import <UIKit/UIKit.h>
#import <UIKit/UIGestureRecognizerSubclass.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <stdbool.h>
#include <SDL3/SDL.h>

@interface SculptPicker : NSObject <UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate>
@property (nonatomic) SDL_DialogFileCallback callback;
@property (nonatomic) void *userdata;
/* A save's file name, joined to the folder picked; nil when a file or folder is opened. */
@property (nonatomic, copy) NSString *name;
/* Whether it picks a folder, whose scope covers everything under it. */
@property (nonatomic) BOOL folder;
@end

/*
 * The picker showing, kept here because UIKit holds a picker's delegate weakly, and nil
 * once it has answered, so it answers once. One at a time: files.odin opens no dialog while
 * another shows.
 */
static SculptPicker *showing;

/*
 * Outside its own container the app may read and write a picked file or folder only while
 * it holds the item's security scope, and it keeps every scope to the end of the run. A
 * file's scope covers that file alone, so a scene opened from Files can be read but not
 * saved over, since a save writes a partial copy and the versions folder beside the file.
 * A folder's covers everything under it, so a scene saved into a picked folder saves there
 * again. `held_folders` holds those folders' paths for sculpt_ios_writable_beside.
 */
static NSMutableArray<NSURL *> *held;
static NSMutableArray<NSString *> *held_folders;

static void answer_path(SDL_DialogFileCallback callback, void *userdata, NSString *path)
{
	const char *list[2] = {path.fileSystemRepresentation, NULL};
	callback(userdata, list, -1);
}

static void answer_cancel(SDL_DialogFileCallback callback, void *userdata)
{
	const char *list[1] = {NULL};
	callback(userdata, list, -1);
}

static void answer_failure(SDL_DialogFileCallback callback, void *userdata, const char *why)
{
	SDL_SetError("%s", why);
	callback(userdata, NULL, -1);
}

/* The controller on top of the window's, which a new picker or alert is presented from. */
static UIViewController *top_controller(SDL_Window *window)
{
	SDL_PropertiesID props = SDL_GetWindowProperties(window);
	UIWindow *uiwindow = (__bridge UIWindow *)SDL_GetPointerProperty(props, SDL_PROP_WINDOW_UIKIT_WINDOW_POINTER, NULL);
	UIViewController *top = uiwindow.rootViewController;
	while (top.presentedViewController) top = top.presentedViewController;
	return top;
}

/*
 * What an open may pick, from SDL filters such as {"Meshes", "obj;ply;stl"}. The system
 * knows nothing of the app's own formats (.sculpt, .strokes, .sculptpack, .workspace) and
 * would grey them out, so a filter naming one, or "*", offers every file, and the app's own
 * check of the bytes decides, as Android's "All files" filters do (files.odin).
 */
static NSArray<UTType *> *content_types(const SDL_DialogFileFilter *filters, int nfilters)
{
	NSMutableArray<UTType *> *types = [NSMutableArray array];
	for (int i = 0; i < nfilters; i++) {
		if (!filters[i].pattern) continue;
		for (NSString *ext in [@(filters[i].pattern) componentsSeparatedByString:@";"]) {
			UTType *type = [ext isEqualToString:@"*"] ? nil : [UTType typeWithFilenameExtension:ext];
			if (!type || type.dynamic) return @[UTTypeItem];
			if (![types containsObject:type]) [types addObject:type];
		}
	}
	return types.count > 0 ? types : @[UTTypeItem];
}

/* The extension a save takes when its name has none: the first filter's first one. */
static NSString *first_extension(const SDL_DialogFileFilter *filters, int nfilters)
{
	if (nfilters < 1 || !filters[0].pattern) return @"";
	NSString *ext = [@(filters[0].pattern) componentsSeparatedByString:@";"].firstObject;
	return [ext isEqualToString:@"*"] ? @"" : ext;
}

/*
 * Where a save named `name` goes in `folder`. A save never replaces a file without asking,
 * and rather than a second alert over the closing picker, a name already in the folder
 * gets a number, as Files numbers copies: "Head 2.sculpt".
 */
static NSString *free_path(NSString *folder, NSString *name)
{
	NSString *path = [folder stringByAppendingPathComponent:name];
	NSString *stem = name.stringByDeletingPathExtension, *ext = name.pathExtension;
	for (int n = 2; [NSFileManager.defaultManager fileExistsAtPath:path]; n++) {
		NSString *numbered = [NSString stringWithFormat:@"%@ %d", stem, n];
		if (ext.length > 0) numbered = [numbered stringByAppendingPathExtension:ext];
		path = [folder stringByAppendingPathComponent:numbered];
	}
	return path;
}

static BOOL is_under(NSString *path, NSString *root)
{
	return [path isEqualToString:root] || [path hasPrefix:[root stringByAppendingString:@"/"]];
}

static void present_picker(SDL_Window *window, UIDocumentPickerViewController *picker, SDL_DialogFileCallback callback, void *userdata, NSString *name, BOOL folder)
{
	UIViewController *top = top_controller(window);
	if (!top) {
		answer_failure(callback, userdata, "the window has no view controller to show the picker from");
		return;
	}
	SculptPicker *delegate = [SculptPicker new];
	delegate.callback = callback;
	delegate.userdata = userdata;
	delegate.name = name;
	delegate.folder = folder;
	showing = delegate;
	picker.delegate = delegate;
	picker.allowsMultipleSelection = NO;
	/*
	 * A sheet that goes away without the picker's Cancel would leave files.odin waiting for
	 * an answer that never comes, and every later dialog refused: so a swipe or a tap
	 * outside does not dismiss it, and if one ever does, that is a cancel.
	 */
	picker.modalInPresentation = YES;
	picker.presentationController.delegate = delegate;
	[top presentViewController:picker animated:YES completion:nil];
}

static void pick_folder(SDL_Window *window, SDL_DialogFileCallback callback, void *userdata, NSString *name)
{
	UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeFolder]];
	/* It starts in the app's Documents folder, which Files shows (UIFileSharingEnabled). */
	NSURL *documents = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
	if (documents && [NSFileManager.defaultManager createDirectoryAtURL:documents withIntermediateDirectories:YES attributes:nil error:NULL]) {
		picker.directoryURL = documents;
	}
	present_picker(window, picker, callback, userdata, name, YES);
}

@implementation SculptPicker

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls
{
	(void)controller;
	if (showing != self) return;
	/* Read before letting go: `showing` is the only strong reference to this delegate. */
	SDL_DialogFileCallback callback = self.callback;
	void *userdata = self.userdata;
	NSString *name = self.name;
	BOOL folder = self.folder;
	showing = nil;
	NSURL *url = urls.firstObject;
	if (!url) {
		answer_cancel(callback, userdata);
		return;
	}
	if ([url startAccessingSecurityScopedResource]) {
		if (!held) held = [NSMutableArray array];
		[held addObject:url];
		if (folder) {
			if (!held_folders) held_folders = [NSMutableArray array];
			[held_folders addObject:url.path.stringByStandardizingPath];
		}
	}
	answer_path(callback, userdata, name ? free_path(url.path, name) : url.path);
}

/* The picker's Cancel, or the sheet dismissed some other way: a cancel, answered once. */
- (void)cancelled
{
	if (showing != self) return;
	SDL_DialogFileCallback callback = self.callback;
	void *userdata = self.userdata;
	showing = nil;
	answer_cancel(callback, userdata);
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller
{
	(void)controller;
	[self cancelled];
}

- (void)presentationControllerDidDismiss:(UIPresentationController *)presentationController
{
	(void)presentationController;
	[self cancelled];
}

@end

void sculpt_ios_open_file_dialog(SDL_DialogFileCallback callback, void *userdata, SDL_Window *window, const SDL_DialogFileFilter *filters, int nfilters)
{
	if (showing) {
		answer_failure(callback, userdata, "another file dialog is showing");
		return;
	}
	UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:content_types(filters, nfilters) asCopy:NO];
	present_picker(window, picker, callback, userdata, nil, NO);
}

void sculpt_ios_open_folder_dialog(SDL_DialogFileCallback callback, void *userdata, SDL_Window *window)
{
	if (showing) {
		answer_failure(callback, userdata, "another file dialog is showing");
		return;
	}
	pick_folder(window, callback, userdata, nil);
}

void sculpt_ios_save_file_dialog(SDL_DialogFileCallback callback, void *userdata, SDL_Window *window, const SDL_DialogFileFilter *filters, int nfilters, const char *default_location)
{
	if (showing) {
		answer_failure(callback, userdata, "another file dialog is showing");
		return;
	}
	UIViewController *top = top_controller(window);
	if (!top) {
		answer_failure(callback, userdata, "the window has no view controller to show the dialog from");
		return;
	}
	NSString *suggested = default_location ? @(default_location).lastPathComponent : @"";
	if (suggested.length == 0) suggested = @"Untitled";
	NSString *ext = first_extension(filters, nfilters);

	UIAlertController *ask = [UIAlertController alertControllerWithTitle:@"Save as" message:@"Name the file, then choose the folder it goes in." preferredStyle:UIAlertControllerStyleAlert];
	[ask addTextFieldWithConfigurationHandler:^(UITextField *field) {
		field.text = suggested;
		field.clearButtonMode = UITextFieldViewModeWhileEditing;
		field.autocapitalizationType = UITextAutocapitalizationTypeNone;
	}];
	/* The alert keeps its actions, which would keep it through their blocks. */
	__weak UIAlertController *weak_ask = ask;
	[ask addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
		(void)action;
		answer_cancel(callback, userdata);
	}]];
	[ask addAction:[UIAlertAction actionWithTitle:@"Choose folder" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
		(void)action;
		NSString *name = [weak_ask.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
		/* A name is one file in the folder chosen, never a path into another. */
		name = [name stringByReplacingOccurrencesOfString:@"/" withString:@"-"];
		if (name.length == 0 || [name hasPrefix:@"."]) name = suggested;
		if (name.pathExtension.length == 0 && ext.length > 0) name = [name stringByAppendingPathExtension:ext];
		pick_folder(window, callback, userdata, name);
	}]];
	[top presentViewController:ask animated:YES completion:nil];
}

/*
 * Whether a save may write beside `path` (file_writable_beside in src/app/files.odin):
 * inside the app's own container, or under a folder picked this run. A file picked alone
 * is not enough (see `held`).
 */
bool sculpt_ios_writable_beside(const char *path)
{
	if (!path) return false;
	NSString *folder = @(path).stringByDeletingLastPathComponent.stringByStandardizingPath;
	if (is_under(folder, NSHomeDirectory().stringByStandardizingPath)) return true;
	for (NSString *root in held_folders) {
		if (is_under(folder, root)) return true;
	}
	return false;
}

/*
 * The Apple Pencil's own gestures and haptics, which SDL 3.4 leaves out: its UIKit driver
 * reads the pencil's pressure, lean, hover and roll (src/app/pencil.odin takes those), but
 * no UIPencilInteraction, so a double-tap or a squeeze never reaches SDL, and nothing plays
 * the Pencil Pro's haptics. One interaction on SDL's view sends each gesture to the app as
 * an SDL user event of the type the app registered: the code is the gesture
 * (Pencil_Gesture: 0 double-tap, 1 to 3 a squeeze beginning, ending or cancelled), data1
 * the iPad's preferred action for it (Pencil_Action, named one by one below, so UIKit's
 * order never matters). The app decides what each does; this only reports.
 */

@interface SculptPencil : NSObject <UIPencilInteractionDelegate>
@property (nonatomic) Uint32 eventType;
@end

/* Kept here, since a view holds its interactions weakly through their delegate. */
static SculptPencil *pencil;
static UIPencilInteraction *pencil_interaction;
static UIView *pencil_view;
/* UICanvasFeedbackGenerator, iPadOS 17.5 and later; nil before. */
static id pencil_haptics;

/* Pencil_Action in src/app/pencil.odin. */
enum {
	ACTION_IGNORE,
	ACTION_SWITCH_ERASER,
	ACTION_SWITCH_PREVIOUS,
	ACTION_COLOR_PALETTE,
	ACTION_INK_ATTRIBUTES,
	ACTION_CONTEXTUAL_PALETTE,
	ACTION_RUN_SHORTCUT,
};

static int pencil_action(UIPencilPreferredAction a)
{
	switch (a) {
	case UIPencilPreferredActionIgnore:         return ACTION_IGNORE;
	case UIPencilPreferredActionSwitchEraser:   return ACTION_SWITCH_ERASER;
	case UIPencilPreferredActionSwitchPrevious: return ACTION_SWITCH_PREVIOUS;
	case UIPencilPreferredActionShowColorPalette: return ACTION_COLOR_PALETTE;
	default: break;
	}
	if (@available(iOS 17.5, *)) {
		switch (a) {
		case UIPencilPreferredActionShowInkAttributes:     return ACTION_INK_ATTRIBUTES;
		case UIPencilPreferredActionShowContextualPalette: return ACTION_CONTEXTUAL_PALETTE;
		case UIPencilPreferredActionRunSystemShortcut:     return ACTION_RUN_SHORTCUT;
		default: break;
		}
	}
	/* One a later iPadOS adds means nothing here yet. */
	return ACTION_IGNORE;
}

static void pencil_send(int gesture, UIPencilPreferredAction preferred)
{
	SDL_Event e;
	SDL_zero(e);
	e.type = pencil.eventType;
	e.user.timestamp = SDL_GetTicksNS();
	e.user.code = gesture;
	e.user.data1 = (void *)(intptr_t)pencil_action(preferred);
	SDL_PushEvent(&e);
}

@implementation SculptPencil

/* Before iPadOS 17.5; from then on the system calls didReceiveTap: instead. */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-implementations"
- (void)pencilInteractionDidTap:(UIPencilInteraction *)interaction
{
	pencil_send(0, UIPencilInteraction.preferredTapAction);
}
#pragma clang diagnostic pop

- (void)pencilInteraction:(UIPencilInteraction *)interaction didReceiveTap:(UIPencilInteractionTap *)tap API_AVAILABLE(ios(17.5))
{
	pencil_send(0, UIPencilInteraction.preferredTapAction);
}

- (void)pencilInteraction:(UIPencilInteraction *)interaction didReceiveSqueeze:(UIPencilInteractionSqueeze *)squeeze API_AVAILABLE(ios(17.5))
{
	int gesture;
	switch (squeeze.phase) {
	case UIPencilInteractionPhaseBegan:     gesture = 1; break;
	case UIPencilInteractionPhaseEnded:     gesture = 2; break;
	case UIPencilInteractionPhaseCancelled: gesture = 3; break;
	default: return; /* a squeeze held changes nothing the app follows */
	}
	pencil_send(gesture, UIPencilInteraction.preferredSqueezeAction);
}

@end

void sculpt_ios_pencil_start(SDL_Window *window, Uint32 event_type)
{
	SDL_PropertiesID props = SDL_GetWindowProperties(window);
	UIWindow *uiwindow = (__bridge UIWindow *)SDL_GetPointerProperty(props, SDL_PROP_WINDOW_UIKIT_WINDOW_POINTER, NULL);
	UIView *view = uiwindow.rootViewController.view;
	if (!view || event_type == 0) return;
	pencil = [SculptPencil new];
	pencil.eventType = event_type;
	/* initWithDelegate: is iPadOS 17.5's; the delegate property works from 12.1. */
	pencil_interaction = [UIPencilInteraction new];
	pencil_interaction.delegate = pencil;
	[view addInteraction:pencil_interaction];
	pencil_view = view;
	if (@available(iOS 17.5, *)) {
		/* A feedback generator belongs to a view from iPadOS 17.5, made by the class. */
		UICanvasFeedbackGenerator *haptics = [UICanvasFeedbackGenerator feedbackGeneratorForView:view];
		pencil_haptics = haptics;
	}
}

/* Whether the iPad's Only Draw with Apple Pencil is on, so a finger never sculpts. */
bool sculpt_ios_pencil_only(void)
{
	return UIPencilInteraction.prefersPencilOnlyDrawing;
}

/* A Pencil Pro haptic at (x, y) in the view's points: 0 something snapped into place, 1 a
 * shape completed. Nothing without a Pencil Pro, before iPadOS 17.5, or while the pencil
 * is away, as UIKit decides. */
void sculpt_ios_haptic(int kind, float x, float y)
{
	if (@available(iOS 17.5, *)) {
		UICanvasFeedbackGenerator *haptics = pencil_haptics;
		if (!haptics) return;
		CGPoint at = CGPointMake(x, y);
		if (kind == 1) [haptics pathCompletedAtLocation:at];
		else [haptics alignmentOccurredAtLocation:at];
	}
}

/*
 * The Apple Pencil's samples between frames, which SDL 3.4 leaves out: UIKit gathers the
 * Pencil's 240 Hz samples of a frame into one touch's coalesced touches, and SDL's view
 * reads only the touch itself (the newest). A recogniser on SDL's view sees each move
 * before the view does and sends every coalesced sample but the last, oldest first, as an
 * SDL user event of the type the app registered (src/app/pen_samples.odin): the offset from
 * the touch's own place in the view's points in data1, the pressure and the azimuth in the
 * view (radians) in data2, the altitude's bits in the code. It never recognises anything,
 * so it neither delays nor cancels a touch SDL's view is given.
 */
@interface SculptSamples : UIGestureRecognizer
@property (nonatomic) Uint32 eventType;
@end

static SculptSamples *samples;

static void samples_send(Uint32 type, CGPoint offset, float pressure, float azimuth, float altitude)
{
	union { float f; Uint32 u; } x = {(float)offset.x}, y = {(float)offset.y}, p = {pressure}, a = {azimuth}, b = {altitude};
	SDL_Event e;
	SDL_zero(e);
	e.type = type;
	e.user.timestamp = SDL_GetTicksNS();
	e.user.data1 = (void *)(uintptr_t)((Uint64)x.u | (Uint64)y.u << 32);
	e.user.data2 = (void *)(uintptr_t)((Uint64)p.u | (Uint64)a.u << 32);
	e.user.code = (Sint32)b.u;
	SDL_PushEvent(&e);
}

/* The predicted sample: its offset from the newest, packed as samples_send packs one. */
static void predicted_send(Uint32 type, CGPoint offset)
{
	union { float f; Uint32 u; } x = {(float)offset.x}, y = {(float)offset.y};
	SDL_Event e;
	SDL_zero(e);
	e.type = type;
	e.user.timestamp = SDL_GetTicksNS();
	e.user.data1 = (void *)(uintptr_t)((Uint64)x.u | (Uint64)y.u << 32);
	SDL_PushEvent(&e);
}

/* Once every touch is up, the recogniser fails, which resets it for the next touches;
 * while another finger stays down it keeps watching the pencil. */
static bool all_touches_over(UIEvent *event)
{
	for (UITouch *touch in event.allTouches) {
		if (touch.phase != UITouchPhaseEnded && touch.phase != UITouchPhaseCancelled) return false;
	}
	return true;
}

@implementation SculptSamples

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
	UIView *view = self.view;
	for (UITouch *touch in touches) {
		if (touch.type != UITouchTypePencil) continue;
		/* Measured as SDL's view measures the touch it reports. */
		CGPoint now = [touch locationInView:view];
		NSArray<UITouch *> *all = [event coalescedTouchesForTouch:touch];
		for (NSUInteger i = 0; i + 1 < all.count; i++) {
			UITouch *c = all[i];
			CGPoint at = [c locationInView:view];
			float pressure = c.maximumPossibleForce > 0 ? (float)(c.force / c.maximumPossibleForce) : -1.0f;
			samples_send(self.eventType, CGPointMake(at.x - now.x, at.y - now.y), pressure, (float)[c azimuthAngleInView:view], (float)c.altitudeAngle);
		}
		/* UIKit's guess at where the Pencil will be by the time a frame shows: the furthest
		 * of its predicted touches, for the brush ring only (cursor_lead in cursor.odin). */
		UITouch *ahead = [event predictedTouchesForTouch:touch].lastObject;
		if (ahead) {
			CGPoint at = [ahead locationInView:view];
			predicted_send(self.eventType + 1, CGPointMake(at.x - now.x, at.y - now.y));
		}
	}
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
	if (all_touches_over(event)) self.state = UIGestureRecognizerStateFailed;
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
	if (all_touches_over(event)) self.state = UIGestureRecognizerStateFailed;
}

@end

void sculpt_ios_samples_start(SDL_Window *window, Uint32 event_type)
{
	SDL_PropertiesID props = SDL_GetWindowProperties(window);
	UIWindow *uiwindow = (__bridge UIWindow *)SDL_GetPointerProperty(props, SDL_PROP_WINDOW_UIKIT_WINDOW_POINTER, NULL);
	UIView *view = uiwindow.rootViewController.view;
	if (!view || event_type == 0) return;
	samples = [[SculptSamples alloc] initWithTarget:nil action:nil];
	samples.eventType = event_type;
	samples.cancelsTouchesInView = NO;
	samples.delaysTouchesBegan = NO;
	samples.delaysTouchesEnded = NO;
	[view addGestureRecognizer:samples];
}

/*
 * Scribble, the Apple Pencil's handwriting, for the app's text fields. The interface draws
 * its fields itself (src/ui), so UIKit cannot see them, and SDL's own text field, which its
 * text input types into, is hidden and has no size; an indirect Scribble interaction on
 * SDL's view asks the app instead. Each frame the app sends where its fields show, in the
 * view's points, and which has the keys (sculpt_ios_scribble_fields). When the pencil
 * begins to write in one, Scribble asks for it: the app gives it the keys at its next frame
 * (sculpt_ios_scribble_wanted) and turns SDL's text input on, which makes SDL's hidden field
 * the first responder, and that field goes to Scribble to write into. SDL sends what is
 * written as text events, as it does the keyboard's.
 */
@interface SculptScribble : NSObject <UIIndirectScribbleInteractionDelegate>
@end

/* MAX_TEXT_FIELDS in src/ui/ui.odin. */
enum { SCRIBBLE_FIELDS = 16 };

static struct {
	Uint64 id;
	CGRect rect;
} scribble_fields[SCRIBBLE_FIELDS];
static int scribble_count;
static Uint64 scribble_focused; /* the field with the keys, 0 for none */
static bool scribble_typing;    /* SDL's text input is on */
static Uint64 scribble_wanted;  /* asked for by Scribble, not yet taken by the app */
static Uint64 scribble_waiting; /* asked for, whose text field Scribble waits for */
static void (^scribble_answer)(UIResponder<UITextInput> *);
static SculptScribble *scribble;
static UIIndirectScribbleInteraction *scribble_interaction;
static UIView *scribble_view;

/* The view under `view` that has the keys and takes text: SDL's hidden field, while its
 * text input is on. */
static UIResponder<UITextInput> *text_responder(UIView *view)
{
	if (view.isFirstResponder && [view conformsToProtocol:@protocol(UITextInput)]) return (UIResponder<UITextInput> *)view;
	for (UIView *sub in view.subviews) {
		UIResponder<UITextInput> *found = text_responder(sub);
		if (found) return found;
	}
	return nil;
}

static Uint64 element_id(UIScribbleElementIdentifier element)
{
	return [element isKindOfClass:[NSNumber class]] ? [(NSNumber *)element unsignedLongLongValue] : 0;
}

/* Answers Scribble's wait for a field with `input`, nil when the field got no keys. */
static void scribble_answer_with(UIResponder<UITextInput> *input)
{
	void (^answer)(UIResponder<UITextInput> *) = scribble_answer;
	scribble_answer = nil;
	scribble_waiting = 0;
	if (answer) answer(input);
}

@implementation SculptScribble

- (void)indirectScribbleInteraction:(UIIndirectScribbleInteraction *)interaction requestElementsInRect:(CGRect)rect completion:(void (^)(NSArray<UIScribbleElementIdentifier> *))completion
{
	NSMutableArray<UIScribbleElementIdentifier> *found = [NSMutableArray array];
	for (int i = 0; i < scribble_count; i++) {
		if (CGRectIntersectsRect(scribble_fields[i].rect, rect)) [found addObject:@(scribble_fields[i].id)];
	}
	completion(found);
}

- (BOOL)indirectScribbleInteraction:(UIIndirectScribbleInteraction *)interaction isElementFocused:(UIScribbleElementIdentifier)element
{
	return scribble_typing && element_id(element) == scribble_focused;
}

- (CGRect)indirectScribbleInteraction:(UIIndirectScribbleInteraction *)interaction frameForElement:(UIScribbleElementIdentifier)element
{
	Uint64 id = element_id(element);
	for (int i = 0; i < scribble_count; i++) {
		if (scribble_fields[i].id == id) return scribble_fields[i].rect;
	}
	return CGRectNull;
}

- (void)indirectScribbleInteraction:(UIIndirectScribbleInteraction *)interaction focusElementIfNeeded:(UIScribbleElementIdentifier)element referencePoint:(CGPoint)focusReferencePoint completion:(void (^)(UIResponder<UITextInput> *))completion
{
	Uint64 id = element_id(element);
	/* A field asked for earlier and not yet given gets nothing now. */
	scribble_answer_with(nil);
	if (id == 0) {
		completion(nil);
		return;
	}
	if (scribble_typing && id == scribble_focused) {
		completion(text_responder(scribble_view));
		return;
	}
	scribble_answer = completion;
	scribble_wanted = id;
	scribble_waiting = id;
}

@end

void sculpt_ios_scribble_start(SDL_Window *window)
{
	SDL_PropertiesID props = SDL_GetWindowProperties(window);
	UIWindow *uiwindow = (__bridge UIWindow *)SDL_GetPointerProperty(props, SDL_PROP_WINDOW_UIKIT_WINDOW_POINTER, NULL);
	UIView *view = uiwindow.rootViewController.view;
	if (!view) return;
	scribble = [SculptScribble new];
	scribble_interaction = [[UIIndirectScribbleInteraction alloc] initWithDelegate:scribble];
	[view addInteraction:scribble_interaction];
	scribble_view = view;
}

/* The frame's fields, `count` of them: their ids and where they show (x, y, width and height
 * in the view's points), the field with the keys and whether SDL's text input is on. A field
 * Scribble waits for gets SDL's text field once it has the keys, or nothing once the app
 * gave them elsewhere. */
void sculpt_ios_scribble_fields(const Uint64 *ids, const float (*rects)[4], int count, Uint64 focused, bool typing)
{
	scribble_count = count < SCRIBBLE_FIELDS ? count : SCRIBBLE_FIELDS;
	for (int i = 0; i < scribble_count; i++) {
		scribble_fields[i].id = ids[i];
		scribble_fields[i].rect = CGRectMake(rects[i][0], rects[i][1], rects[i][2], rects[i][3]);
	}
	scribble_focused = focused;
	scribble_typing = typing;
	if (scribble_waiting == 0 || scribble_wanted != 0) return;
	if (typing && focused == scribble_waiting) scribble_answer_with(text_responder(scribble_view));
	else scribble_answer_with(nil);
}

/* The field Scribble asked for since the app last asked, 0 for none. */
Uint64 sculpt_ios_scribble_wanted(void)
{
	Uint64 id = scribble_wanted;
	scribble_wanted = 0;
	return id;
}
