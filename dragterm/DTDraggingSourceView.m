//
//  DTDraggingSourceView.m
//  drag
//
//  Created by Nate Weaver on 2019-06-07.
//  Copyright © 2019 Nate Weaver/Derailer. All rights reserved.
//

#import "DTDraggingSourceView.h"
#import "DTActivation.h"
#import "DTLog.h"

@interface DTDraggingSourceView ()

@property (nonatomic, copy)	NSImage *icon;
@property (nonatomic, readwrite) BOOL dragSessionStarted;

- (void)beginDragWithEvent:(NSEvent *)event;
- (void)startDragAtCursor;

@end

static NSRect DTCenterRect(NSRect baseRect, CGFloat rectDim) {
	NSRect rect = NSZeroRect;
	rect.size = (NSSize){ rectDim, rectDim };
	rect.origin = (NSPoint){ (baseRect.size.width - rectDim) / 2.0, (baseRect.size.height - rectDim) / 2.0};
	return rect;
}

static BOOL DTClickToActivate(void) {
	static BOOL flag;
	static dispatch_once_t onceToken;

	dispatch_once(&onceToken, ^{
		// Messaging nil returns 0, so an unset variable reads as NO here, which is what we want.
		flag = [NSProcessInfo.processInfo.environment[@"DRAG_CLICK_TO_ACTIVATE"] boolValue];
	});

	return flag;
}

@implementation DTDraggingSourceView

- (void)viewDidMoveToWindow {
	if (self.window == nil)
		return;

	[[NSNotificationCenter defaultCenter] addObserver:self
			selector:@selector(applicationDidBecomeActive:)
				name:NSApplicationDidBecomeActiveNotification
				object:NSApp];
}

- (void)dealloc {
	[[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)applicationDidBecomeActive:(NSNotification *)note {
	DTLog(@"app became active, left button held %d", (NSEvent.pressedMouseButtons & 1) != 0);

	// The click that activated us is consumed by the activation itself, so the drag has to be
	// started from here, while the button is still held.
	if (DTClickToActivate() && (NSEvent.pressedMouseButtons & 1) != 0)
		[self startDragAtCursor];
}

- (void)startDragAtCursor {
	if (self.dragSessionStarted)
		return;

	NSWindow *window = self.window;
	NSPoint screenPoint = NSEvent.mouseLocation;

		NSEvent *event = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown
		                          location:[window convertPointFromScreen:screenPoint]
		                     modifierFlags:0
		                         timestamp:NSProcessInfo.processInfo.systemUptime
		                      windowNumber:window.windowNumber
		                           context:nil
		                       eventNumber:0
		                        clickCount:1
		                          pressure:1.0];

	DTLog(@"starting drag from activation at %@", NSStringFromPoint(screenPoint));
	[self beginDragWithEvent:event];
}

- (void)draggingSession:(NSDraggingSession *)session willBeginAtPoint:(NSPoint)screenPoint {
	DTLog(@"dragging session will begin at %@, app active %d", NSStringFromPoint(screenPoint), NSApp.isActive);

	// Hiding the window is what keeps the transparent source window from eating the drop,
	// but it has to happen here rather than before beginDraggingSessionWithItems:event:source:.
	// The drag image is clipped to the visible area of the source view, so a window that is
	// already ordered out when the session is created yields a drag image clipped to nothing.
	[self.window orderOut:nil];
}

- (void)draggingSession:(NSDraggingSession *)session endedAtPoint:(NSPoint)screenPoint operation:(NSDragOperation)operation {
	DTLog(@"dragging session ended at %@, operation %lu, app active %d", NSStringFromPoint(screenPoint), (unsigned long)operation, NSApp.isActive);

	if (operation == NSDragOperationDelete) {
		[NSWorkspace.sharedWorkspace recycleURLs:self.URLs completionHandler:^(NSDictionary<NSURL *,NSURL *> * _Nonnull newURLs, NSError * _Nullable error) {
			[NSApp terminate:nil];
		}];
	} else {
		[NSApp terminate:nil];
	}
}

- (NSDragOperation)draggingSession:(nonnull NSDraggingSession *)session sourceOperationMaskForDraggingContext:(NSDraggingContext)context {
	return NSDragOperationEvery;
}

- (void)setURLs:(NSArray<NSURL *> *)urls {
	_URLs = [urls copy];
	NSImage *icon;

	if (urls.count == 1) {
		NSURL *firstUrl = urls.firstObject;
		[firstUrl getResourceValue:&icon forKey:NSURLEffectiveIconKey error:nil];
	} else
		icon = [NSImage imageNamed:NSImageNameMultipleDocuments];

	self.icon = icon;
}

- (void)drawRect:(NSRect)dirtyRect {
	[self.icon drawInRect:DTCenterRect(self.bounds, self.iconSize)];
}

- (BOOL)acceptsFirstMouse:(NSEvent *)event {
	// Default mode: take the first click without activating, which is what lets a process the
	// shell started start a drag at all. Under DRAG_CLICK_TO_ACTIVATE the opposite is wanted:
	// let that click activate the app (a drag is only negotiated with a destination while the
	// source is active), and start the drag from the activation callback instead.
	return !DTClickToActivate();
}

- (BOOL)acceptsFirstResponder {
	return YES;
}

- (void)mouseDown:(NSEvent *)event {
	DTLog(@"mouse down at %@, app active %d", NSStringFromPoint(event.locationInWindow), NSApp.isActive);

	// Belt and braces: if the activation at launch was refused, ask again now, while the
	// button is still held. A drag started by an inactive app never reaches a destination.
	if (!NSApp.isActive) {
		DTLog(@"activating before starting the drag session");
		DTActivateApp();
	}

	[self beginDragWithEvent:event];
}

- (void)beginDragWithEvent:(NSEvent *)event {
	NSMutableArray<NSDraggingItem *> *items = [NSMutableArray arrayWithCapacity:self.URLs.count];

	for (NSURL *url in self.URLs) {
		NSDraggingItem *item = [[NSDraggingItem alloc] initWithPasteboardWriter:url];
		NSImage *icon;
		CGFloat iconSize = self.iconSize;
		[url getResourceValue:&icon forKey:NSURLEffectiveIconKey error:nil];

		item.draggingFrame = DTCenterRect(self.bounds, iconSize);

		item.imageComponentsProvider = ^NSArray<NSDraggingImageComponent *> *{
			NSDraggingImageComponent *iconComponent = [NSDraggingImageComponent draggingImageComponentWithKey:NSDraggingImageComponentIconKey];
			iconComponent.contents = [NSImage imageWithSize:(NSSize){ iconSize, iconSize } flipped:NO drawingHandler:^BOOL(NSRect dstRect) {
				[icon drawInRect:dstRect];
				return icon != nil;
			}];
			iconComponent.frame = (NSRect){ { 0.0, 0.0 }, { iconSize, iconSize } };
			return @[iconComponent];
		};

		[items addObject:item];
	}

	NSDraggingSession *session = [self beginDraggingSessionWithItems:items event:event source:self];
	self.dragSessionStarted = session != nil;

	if (session == nil) {
		DTLog(@"drag session failed to begin; restoring window");
		[self.window orderFront:nil];
	}
}

@end
