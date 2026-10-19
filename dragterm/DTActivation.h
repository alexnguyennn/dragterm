//
//  DTActivation.h
//  dragterm
//
//  Bringing the process up as an application the WindowServer will let it drag from.
//

#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <dlfcn.h>

NS_ASSUME_NONNULL_BEGIN

// LaunchServices keeps no record of a process that was exec'd from a shell: `lsappinfo info
// -pid` reports a NULL activation policy, NULL visibility, NULL active, and the process does
// not appear in `lsappinfo list` at all. Without that record there is no Dock connection, no
// way to be activated, and - the part that matters here - no cross-process drag session.
// beginDraggingSessionWithItems: still succeeds and still draws a drag image, but that image
// is ours alone: no destination application is ever told a drag is under way, so nothing ever
// highlights and the mouse up is delivered to whichever application is frontmost.
//
// The Carbon-era check-in entry points are still exported, and calling them makes the record
// exist. _RegisterApplication has to come first: TransformProcessType answers paramErr (-50)
// for an unregistered process and noErr once it is registered.
//
// Private API, so this is wrapped in a probe-and-skip: if a future system stops exporting it,
// the calls report failure in the debug log and the tool carries on as before.
extern OSStatus _RegisterApplication(int32_t connectionID, CFDictionaryRef _Nullable info);
extern int32_t _CGSDefaultConnection(void);

typedef OSStatus (*DTLSApplicationCheckInFunction)(pid_t, CFDictionaryRef);

static inline DTLSApplicationCheckInFunction DTLSApplicationCheckIn(void) {
	static DTLSApplicationCheckInFunction function;
	static dispatch_once_t onceToken;

	dispatch_once(&onceToken, ^{
		void *handle = dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_NOW);

		if (handle != NULL)
			function = (DTLSApplicationCheckInFunction)dlsym(handle, "_LSApplicationCheckIn");
	});

	return function;
}

typedef struct {
	OSStatus registerStatus;
	OSStatus checkInStatus;
} DTLaunchServicesCheckIn;

// Returns both statuses so the caller can log them: noErr on both means LaunchServices now
// keeps a record of this process as an application.
static inline DTLaunchServicesCheckIn DTCheckInWithLaunchServices(void) {
	DTLaunchServicesCheckIn statuses = { paramErr, paramErr };

	statuses.registerStatus = _RegisterApplication(_CGSDefaultConnection(), NULL);

	DTLSApplicationCheckInFunction checkIn = DTLSApplicationCheckIn();

	if (checkIn != NULL) {
		CFBundleRef bundle = CFBundleGetMainBundle();
		CFDictionaryRef info = bundle != NULL ? CFBundleGetInfoDictionary(bundle) : NULL;

		statuses.checkInStatus = checkIn(getpid(), info);
	}

	return statuses;
}

// The classic trick for a process started from a shell: LaunchServices only lets a process
// it launched itself become the active application, so -[NSApplication activate] is refused
// for one that was exec'd. TransformProcessType registers the running process with
// LaunchServices as a foreground app, which is what a drag session needs: a drag started by
// an inactive app is never negotiated with a destination, so nothing highlights and the
// mouse up is delivered to whoever is active instead of us.
static inline OSStatus DTBecomeForegroundApp(void) {
	// kCurrentProcess as the PSN, not GetCurrentProcess(): that call is a deprecated stub
	// that hands back a PSN LaunchServices has never heard of, and TransformProcessType then
	// fails with procNotFound (-600).
	ProcessSerialNumber psn = { 0, kCurrentProcess };

	return TransformProcessType(&psn, kProcessTransformToForegroundApplication);
}

static inline void DTActivateApp(void) {
	// -activate is the modern spelling; -activateIgnoringOtherApps: is what older systems
	// have. Either can be refused for a process LaunchServices will not make active, which
	// is what DTActivationPolicy is about.
	if (@available(macOS 14.0, *))
		[NSApp activate];
	else
		[NSApp activateIgnoringOtherApps:YES];
}

static inline NSApplicationActivationPolicy DTActivationPolicy(void) {
	NSString *override = NSProcessInfo.processInfo.environment[@"DRAG_POLICY"];

	// Careful: messaging nil returns 0 and NSOrderedSame is 0, so comparing a message to nil
	// against NSOrderedSame is true. An unset DRAG_POLICY would otherwise read as "accessory".
	if (override != nil) {
		if ([override caseInsensitiveCompare:@"accessory"] == NSOrderedSame)
			return NSApplicationActivationPolicyAccessory;

		if ([override caseInsensitiveCompare:@"regular"] == NSOrderedSame)
			return NSApplicationActivationPolicyRegular;
	}

	// An LSUIElement bundle is an agent: LaunchServices will not make it the active
	// application, and a drag started by an inactive app is never negotiated with a
	// destination (no highlight, and the mouse up goes to whoever is active). So an agent
	// bundle cannot host a drag, and only the regular bundle can. DRAG_POLICY overrides
	// this for experimentation.
	return [[NSBundle.mainBundle objectForInfoDictionaryKey:@"LSUIElement"] boolValue]
		? NSApplicationActivationPolicyAccessory
		: NSApplicationActivationPolicyRegular;
}

NS_ASSUME_NONNULL_END
