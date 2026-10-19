//
//  main.m
//  dragterm
//
//  Created by Nate Weaver on 2019-06-07.
//  Copyright © 2019 Nate Weaver/Derailer. All rights reserved.
//

#import <Cocoa/Cocoa.h>
#import "DTDraggingSourceView.h"
#import <getopt.h>
#import <termios.h>

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
	FILE *out = stdErr ? stderr : stdout;

	fprintf(out, "Usage: %s [options] <files>\n", getprogname());
	fprintf(out, "  -c, --clipboard  put the files on the clipboard instead of dragging\n");
	fprintf(out, "  -d, --drag       drag, even on a macOS version where dragging is unavailable\n");
	fprintf(out, "  -v, --version    print the version\n");
	fprintf(out, "  -h, --help       print this message\n");
}

// On macOS 26 and later, dragging from a process started by a shell cannot reach another
// application: LaunchServices keeps no application record for such a process, and without one
// the drag session is never advertised. The icon still follows the pointer, because we draw
// and move it ourselves, but no destination ever highlights and the button release is
// delivered to whichever application is frontmost. Measured at length in
// docs/macos26-drag-blocked.md on the exp/macos26-drag-blocked branch; a vanilla 40-line
// AppKit app behaves the same, so it is not something this tool does.
//
// Putting the files on the clipboard needs no application record, so that is what happens on
// those versions unless --drag says otherwise. Older systems keep dragging, which means no
// per-machine configuration is needed and a machine that upgrades changes behaviour on its
// own.
typedef NS_ENUM(NSInteger, DTDeliveryModeKind) {
	DTDeliveryModeUnset,
	DTDeliveryModeDrag,
	DTDeliveryModeClipboard
};

static DTDeliveryModeKind DTDeliveryMode = DTDeliveryModeUnset;

static BOOL DTDraggingIsUnavailable(void) {
	if (@available(macOS 26.0, *))
		return YES;

	return NO;
}

static BOOL DTShouldUseClipboard(void) {
	if (DTDeliveryMode == DTDeliveryModeClipboard)
		return YES;

	if (DTDeliveryMode == DTDeliveryModeDrag)
		return NO;

	return DTDraggingIsUnavailable();
}

// Put the files on the clipboard as file references.
//
// This is not a shortcut around NSPasteboard: writing a file URL with -[NSPasteboard
// writeObjects:] fails for a process LaunchServices has no record of - it returns NO and the
// change count does not move - which on macOS 26 is what a process started from a shell is.
// osascript puts a real file reference («class furl») on the clipboard, which is what Finder,
// Mail, Slack and browser upload fields accept as a paste.
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

	if (DTDeliveryMode == DTDeliveryModeUnset && DTDraggingIsUnavailable())
		fprintf(stderr, "dragging is unavailable on this macOS version; pass --drag to try it anyway\n");

	return 0;
}

static int parseArguments(int argc, char * const argv[]) {
	struct option longopts[] = {
		{ "version", no_argument, NULL, 'v' },
		{ "help", no_argument, NULL, 'h' },
		{ "clipboard", no_argument, NULL, 'c' },
		{ "drag", no_argument, NULL, 'd' },
		{ NULL, 0, NULL, 0 }
	};
	int c;

	while ((c = getopt_long(argc, argv, "vhcd", longopts, NULL)) != -1) {
		switch (c) {
			case 'v':
				printVersion();
				exit(0);
			case 'h':
				printUsage(NO);
				exit(0);
			case 'c':
				DTDeliveryMode = DTDeliveryModeClipboard;
				break;
			case 'd':
				DTDeliveryMode = DTDeliveryModeDrag;
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

static void DTRestoreTermios(void) {
	if (DTTermiosSaved)
		tcsetattr(STDIN_FILENO, TCSANOW, &DTSavedTermios);
}

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

		if (argc < 1)
			return 1;

		NSApplicationLoad();

		NSMutableArray<NSURL *> *urls = [NSMutableArray arrayWithCapacity:argc - 1];

		for (int i = 0; i < argc; ++i) {
			NSURL *fileURL = [NSURL fileURLWithPath:@(argv[i])].absoluteURL;

			if (![fileURL checkResourceIsReachableAndReturnError:nil]) {
				fprintf(stderr, "Couldn't find file: %s\n", argv[i]);
				return 1;
			}

			[urls addObject:fileURL];
		}

		if (DTShouldUseClipboard())
			return DTCopyToClipboard(urls);

		if (urls.count == 1)
			printf("Dragging %s\n", urls[0].path.UTF8String);
		else
			printf("Dragging %lu files\n", urls.count);

		NSRect frame = (NSRect){ { 0.0, 0.0 }, { 256.0, 256.0 }};

		NSWindow *window = [[NSWindow alloc] initWithContentRect:frame styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
		window.opaque = NO;
		window.backgroundColor = NSColor.clearColor;
		window.level = NSStatusWindowLevel;
		window.ignoresMouseEvents = NO;

		DTDraggingSourceView *sourceView = [[DTDraggingSourceView alloc] initWithFrame:frame];
		window.contentView = sourceView;
		sourceView.iconSize = 64.0;
		sourceView.URLs = urls;

		NSPoint mouseLocation = NSEvent.mouseLocation;
		frame.origin = mouseLocation;
		frame.origin.x -= frame.size.width / 2.0;
		frame.origin.y -= frame.size.height / 2.0;
		[window setFrame:frame display:YES];

		[window orderFront:nil];

		NSFileHandle.fileHandleWithStandardInput.readabilityHandler = ^(NSFileHandle *fileHandle) {
			NSData *data = fileHandle.availableData;

			// No bytes means end of file, which is how launchers such as yazi run this: stdin is
			// closed, so there is no keyboard to cancel with. The readability handler keeps
			// firing on EOF, so falling through to the bell rang it over a million times into a
			// terminal nobody was reading. Detach, and do not cancel: on EOF there is nothing to
			// cancel a drag from.
			if (data.length == 0) {
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

		// This puts the terminal into raw mode to watch for the cancel keys, and it is often
		// launched from inside a full-screen TUI that owns that terminal. Put the settings back
		// on the way out so an exit never leaves the caller with a cooked or dead-looking
		// terminal.
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

		while (1) {
			NSEvent *event = [NSApp nextEventMatchingMask:NSEventMaskAny untilDate:NSDate.distantFuture inMode:NSEventTrackingRunLoopMode dequeue:YES];
			[NSApp sendEvent:event];
		}
	}

	return 0;
}
