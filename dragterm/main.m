//
//  main.m
//  dragterm
//
//  Created by Nate Weaver on 2019-06-07.
//  Copyright © 2019 Nate Weaver/Derailer. All rights reserved.
//

#import <Cocoa/Cocoa.h>
#import "DTActivation.h"
#import "DTDraggingSourceView.h"
#import "DTLog.h"
#import <getopt.h>
#import <termios.h>

// Dragging the icon away from where it appeared is a cancel gesture for the case where
// nobody can type: launchers such as yazi run this with stdin closed, so Escape and q are
// unavailable. It has to be generous, because the whole point is dragging from a terminal to
// an application on the other side of the screen. DRAG_CANCEL_RADIUS sets it in points.
static CGFloat DTCancelRadius(void) {
	static CGFloat radius;
	static dispatch_once_t onceToken;

	dispatch_once(&onceToken, ^{
		radius = [NSProcessInfo.processInfo.environment[@"DRAG_CANCEL_RADIUS"] doubleValue];

		if (radius <= 0.0)
			radius = 1500.0;
	});

	return radius;
}

static NSString *ASCIIfy(NSString *str) {
	str = [str stringByReplacingOccurrencesOfString:@"©" withString:@"Copyright"];
	str = [str stringByReplacingOccurrencesOfString:@"–" withString:@"-"]; // en dash to hyphen
	return str;
}

static void printVersion(void) {
	NSBundle *bundle = NSBundle.mainBundle;

	NSString *shortVersion = [bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
	NSString *bundleVersion = [bundle objectForInfoDictionaryKey:@"CFBundleVersion"];
	NSString *copyright = [bundle objectForInfoDictionaryKey:@"NSHumanReadableCopyright"];

	printf("dragterm %s (v%s)\n", shortVersion.UTF8String, bundleVersion.UTF8String);
	printf("%s\n", ASCIIfy(copyright).UTF8String);
}

static void printUsage(BOOL stdErr) {
	fprintf(stdErr ? stderr : stdout, "Usage: %s [-c|--clipboard] [--] <files>\n", getprogname());
	fprintf(stdErr ? stderr : stdout, "  -c, --clipboard  put the files on the clipboard instead of dragging\n");
}

static BOOL DTCopyToClipboardRequested = NO;

// `open` sometimes leaves a locally built bundle stopped at _dyld_start, and a process that
// never reaches main leaves no trace anywhere: not in the unified log, not on stderr (which
// `open` may not connect at all). So the self-test announces itself on disk, which is the one
// signal that survives both a held launch and a detached stdio. probe-open.sh reads it.
static void DTSelfTestMarker(NSString *line) {
	FILE *file = fopen("/tmp/dragterm-selftest.log", "a");

	if (file == NULL)
		return;

	fprintf(file, "pid %d: %s\n", getpid(), line.UTF8String);
	fclose(file);
}

// Put the files on the clipboard as file references instead of dragging them.
//
// This is not a shortcut around NSPasteboard: writing a file URL with -[NSPasteboard
// writeObjects:] simply fails for a process LaunchServices has no record of (it returns NO
// and the change count does not move), which is what a process started from a shell is on
// macOS 26. osascript puts a real file reference («class furl») on the clipboard, which is
// what Finder, Mail, Slack and friends accept as a paste.
static int DTCopyToClipboard(NSArray<NSURL *> *urls) {
	NSMutableString *items = [NSMutableString string];

	for (NSURL *url in urls) {
		NSString *path = [url.path stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];

		path = [path stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];

		if (items.length > 0)
			[items appendString:@", "];

		[items appendFormat:@"POSIX file \"%@\"", path];
	}

	NSString *script = urls.count == 1
		? [NSString stringWithFormat:@"set the clipboard to %@", items]
		: [NSString stringWithFormat:@"set the clipboard to {%@}", items];

	NSTask *task = [[NSTask alloc] init];
	task.launchPath = @"/usr/bin/osascript";
	task.arguments = @[ @"-e", script ];

	@try {
		[task launch];
	} @catch (NSException *exception) {
		fprintf(stderr, "Couldn't start osascript: %s\n", exception.reason.UTF8String);
		return 1;
	}

	[task waitUntilExit];

	if (task.terminationStatus != 0) {
		fprintf(stderr, "Couldn't put the files on the clipboard (osascript exited %d)\n", (int)task.terminationStatus);
		return 1;
	}

	if (urls.count == 1)
		printf("Copied 1 file to the clipboard; paste with Cmd-V.\n");
	else
		printf("Copied %lu files to the clipboard; paste with Cmd-V.\n", (unsigned long)urls.count);

	return 0;
}

static int parseArguments(int argc, char * const argv[]) {
	struct option longopts[] = {
		{ "version", no_argument, NULL, 'v' },
		{ "help", no_argument, NULL, 'h' },
		{ "debug", no_argument, NULL, 'd' },
		{ "selftest", no_argument, NULL, 's' },
		{ "clipboard", no_argument, NULL, 'c' },
		{ NULL, 0, NULL, 0 }
	};
	int c;

	while ((c = getopt_long(argc, argv, "vhc", longopts, NULL)) != -1) {
		switch (c) {
			case 'v':
				printVersion();
				exit(0);
			case 'h':
				printUsage(NO);
				exit(0);
			case 'd':
				// When the app is started by LaunchServices (`open`), the shell's environment
				// does not reach it, so the debug switches have to arrive as arguments.
				setenv("DRAG_DEBUG", "1", 1);
				break;
			case 's':
				setenv("DRAG_SELFTEST", "1", 1);
				break;
			case 'c':
				DTCopyToClipboardRequested = YES;
				break;
		}
	}

	return optind;
}

static void signalHandler(int signum) {
	exit(0);
}

static struct termios DTSavedTermios;
static BOOL DTTermiosSaved = NO;

// This tool puts the terminal into raw mode to watch for the cancel keys, and it is often
// launched from inside a full-screen TUI (yazi and friends) that owns that terminal. Put
// the settings back on the way out so an exit never leaves the caller with a cooked or
// dead-looking terminal.
static void DTRestoreTermios(void) {
	if (DTTermiosSaved)
		tcsetattr(STDIN_FILENO, TCSANOW, &DTSavedTermios);
}

static NSString *DTEventName(NSEventType type) {
	switch (type) {
		case NSEventTypeLeftMouseDown: return @"left mouse down";
		case NSEventTypeLeftMouseUp: return @"left mouse up";
		case NSEventTypeLeftMouseDragged: return @"left mouse dragged";
		case NSEventTypeMouseEntered: return @"mouse entered";
		case NSEventTypeMouseExited: return @"mouse exited";
		case NSEventTypeMouseMoved: return @"mouse moved";
		case NSEventTypeKeyDown: return @"key down";
		default: return nil;
	}
}

@interface DTBorderlessWindow : NSWindow
@end

@implementation DTBorderlessWindow

- (BOOL)canBecomeKeyWindow {
	// Borderless windows refuse key status by default, which would keep the drag source
	// from ever becoming the key window when the click activates the app.
	return YES;
}

@end

int main(int argc, char * const argv[]) {
	@autoreleasepool {
		signal(SIGINT, signalHandler);

		if (argc < 2) {
			printUsage(YES);
			return 1;
		}

		int diff = parseArguments(argc, argv);
		argc -= diff;
		argv += diff;

		if ([NSProcessInfo.processInfo.environment[@"DRAG_SELFTEST"] boolValue])
			DTSelfTestMarker([NSString stringWithFormat:@"entered main, argv0 %s", argv[0]]);

		if (argc < 1)
			return 1;

		NSApplicationLoad();

		// A bare, non-bundled executable comes up as NSApplicationActivationPolicyProhibited,
		// which can never be activated: macOS 26 hands it pointer motion but never a click, so
		// the drag can't start. install.sh guarantees we are running from inside an app bundle
		// so LaunchServices will honour the policy below.
		DTLaunchServicesCheckIn checkIn = DTCheckInWithLaunchServices();
		OSStatus transformStatus = DTBecomeForegroundApp();
		[NSApp setActivationPolicy:DTActivationPolicy()];

		NSMutableArray<NSURL *> *urls = [NSMutableArray arrayWithCapacity:argc - 1];

		for (int i = 0; i < argc; ++i) {
			NSURL *fileURL = [NSURL fileURLWithPath:@(argv[i])].absoluteURL;

			if (![fileURL checkResourceIsReachableAndReturnError:nil]) {
				fprintf(stderr, "Couldn't find file: %s\n", argv[i]);
				return 1;
			}

			[urls addObject:fileURL];
		}

		if (urls.count == 1)
			printf("Dragging %s\n", urls[0].path.UTF8String);
		else
			printf("Dragging %lu files\n", urls.count);

		if (DTCopyToClipboardRequested)
			return DTCopyToClipboard(urls);

		if (DTDebugEnabled()) {
			DTLog(@"logging on (built %s %s)", __DATE__, __TIME__);
			DTLog(@"bundle %@, LSUIElement %@", NSBundle.mainBundle.bundlePath,
				[NSBundle.mainBundle objectForInfoDictionaryKey:@"LSUIElement"]);
			DTLog(@"_RegisterApplication -> %d, _LSApplicationCheckIn -> %d, TransformProcessType -> %d",
				(int)checkIn.registerStatus, (int)checkIn.checkInStatus, (int)transformStatus);
			DTLog(@"requested policy %ld, effective policy %ld, cancel radius %.0f",
				(long)DTActivationPolicy(), (long)NSApp.activationPolicy, DTCancelRadius());
		}

		NSRect frame = (NSRect){ { 0.0, 0.0 }, { 256.0, 256.0 }};

		DTBorderlessWindow *window = [[DTBorderlessWindow alloc] initWithContentRect:frame styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
		window.opaque = NO;
		window.backgroundColor = NSColor.clearColor;
		window.level = NSStatusWindowLevel;
		window.ignoresMouseEvents = NO;

		DTDraggingSourceView *sourceView = [[DTDraggingSourceView alloc] initWithFrame:frame];
		window.contentView = sourceView;
		sourceView.iconSize = 64.0;
		sourceView.URLs = urls;

		// The window is placed under the pointer once here, then kept there by the timer
		// below, so the press that starts the drag can't land outside it.
		NSPoint origin = NSEvent.mouseLocation;
		frame.origin = origin;
		frame.origin.x -= frame.size.width / 2.0;
		frame.origin.y -= frame.size.height / 2.0;
		[window setFrame:frame display:YES];

		[window orderFront:nil];

		// A drag session only negotiates with destination applications while this is the active
		// application. An inactive app can still start a session and draw its drag image, but
		// destinations never highlight and the mouse up is delivered to whoever is active, so
		// the session is left hanging. acceptsFirstMouse: deliberately takes the click without
		// activating, so activation has to happen here instead.
		DTActivateApp();

		__block NSPoint lastCursor = origin;

		// LaunchServices hands a process an activation context; a process exec'd straight from a
		// terminal does not get one however the policy is set, which is why every activate call
		// above has come back with the app still inactive. DRAG_SELFTEST answers that question
		// without needing anyone to press anything:
		//
		//   open -n --env DRAG_DEBUG=1 --env DRAG_SELFTEST=1 --stderr /tmp/drag.log \
		//        ~/.local/share/dragterm/drag-regular.app --args somefile
		//
		if ([NSProcessInfo.processInfo.environment[@"DRAG_SELFTEST"] boolValue]) {
			dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
				DTSelfTestMarker([NSString stringWithFormat:@"active %d, frontmost %@, policy %ld",
					NSApp.isActive, NSWorkspace.sharedWorkspace.frontmostApplication.localizedName,
					(long)NSApp.activationPolicy]);

				DTLog(@"selftest: app active %d, frontmost %@, policy %ld, window %@", NSApp.isActive,
					NSWorkspace.sharedWorkspace.frontmostApplication.localizedName, (long)NSApp.activationPolicy,
					NSStringFromRect(window.frame));
				exit(0);
			});
		}

		NSTimer *watch = [NSTimer timerWithTimeInterval:0.05 repeats:YES block:^(NSTimer *timer) {
			// Once the session is under way the window is hidden and the pointer belongs to
			// the drag.
			if (sourceView.dragSessionStarted) {
				[timer invalidate];
				return;
			}

			NSPoint cursor = NSEvent.mouseLocation;

			if (hypot(cursor.x - origin.x, cursor.y - origin.y) > DTCancelRadius()) {
				DTLog(@"cancelled: pointer %.0f pt from the drop point", hypot(cursor.x - origin.x, cursor.y - origin.y));
				exit(0);
			}

			NSRect newFrame = window.frame;
			newFrame.origin = (NSPoint){ cursor.x - newFrame.size.width / 2.0, cursor.y - newFrame.size.height / 2.0 };

			if (!NSEqualRects(newFrame, window.frame)) {
				[window setFrame:newFrame display:NO];

				if (DTDebugEnabled() && hypot(cursor.x - lastCursor.x, cursor.y - lastCursor.y) > 24.0) {
					DTLog(@"following to %@, app active %d", NSStringFromPoint(cursor), NSApp.isActive);
					lastCursor = cursor;
				}
			}
		}];

		[[NSRunLoop currentRunLoop] addTimer:watch forMode:NSRunLoopCommonModes];

		// Key events only reach us when we are the active application, which is the case when
		// the launch was handed to LaunchServices rather than exec'd from the shell. That
		// launch path has no stdin at all, so this is the only keyboard cancel route it has.
		[NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent *event) {
			NSString *keys = event.charactersIgnoringModifiers;
			unichar first = keys.length > 0 ? [keys characterAtIndex:0] : 0;

			if (first == 0x1b || first == 'q' || first == 0x04) { // Escape, q, Ctrl-D
				DTLog(@"cancelled from the keyboard");
				exit(0);
			}

			return event;
		}];

		if (DTDebugEnabled()) {
			// Local monitors fire on -[NSApplication sendEvent:], so this reports whether
			// AppKit is dispatching events to this process at all.
			[NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskAny handler:^NSEvent *(NSEvent *event) {
				NSString *name = DTEventName(event.type);

				if (name != nil)
					DTLog(@"dispatched %@", name);

				return event;
			}];

			// One-shot activation probe, so the log shows whether activation was accepted
			// without needing anyone to move the mouse.
			dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
				DTLog(@"app active %d, frontmost app %@", NSApp.isActive,
					NSWorkspace.sharedWorkspace.frontmostApplication.localizedName);
			});
		}

		NSFileHandle.fileHandleWithStandardInput.readabilityHandler = ^(NSFileHandle *fileHandle) {
			NSData *data = fileHandle.availableData;

			// No bytes means end of file: stdin is closed or redirected. The readability handler
			// keeps firing on EOF, so treating it as "somebody typed something we don't
			// understand" rings the bell in a tight loop forever. Detach instead of quitting:
			// launchers such as yazi run this with stdin closed, and cancelling there is wrong.
			if (data.length == 0) {
				DTLog(@"stdin closed; keyboard cancel unavailable");
				fileHandle.readabilityHandler = nil;
				return;
			}

			if (data.length == 1) {
				char *bytes = (char *)data.bytes;

				if (bytes[0] == '\e' || bytes[0] == 0x04 || bytes[0] == 'q') // 0x04 is END OF TRANSMISSION (Ctrl-D)
					exit(0);
			}

			putc('\a', stderr);
		};

		struct termios info;

		if (tcgetattr(0, &DTSavedTermios) == 0) {
			DTTermiosSaved = YES;
			atexit(DTRestoreTermios);
		}

		tcgetattr(0, &info);
		info.c_lflag &= ~(ICANON | ECHO);
		info.c_cc[VMIN] = 0;
		info.c_cc[VTIME] = 0;
		tcsetattr(0, TCSANOW, &info);

		// Draining the event queue by hand never calls -[NSApplication run], so
		// -[NSApplication finishLaunching] never happens and the app stays half-initialized:
		// the drag session starts and renders a drag image, but never completes the
		// destination handshake or ends when the button is released. This also only drained
		// the event-tracking mode, while drag sessions are serviced in the default mode.
		// Termination happens through -[NSApplication terminate:] when the session ends.
		[NSApp run];
	}

	return 0;
}
