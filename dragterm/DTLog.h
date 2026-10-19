//
//  DTLog.h
//  dragterm
//
//  Debug logging shared by main and the drag source view. Enable with DRAG_DEBUG=1.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

static inline BOOL DTDebugEnabled(void) {
	return NSProcessInfo.processInfo.environment[@"DRAG_DEBUG"] != nil;
}

// Deliberately not NSLog: this is a bare command-line process, and NSLog output from one
// goes neither to the terminal nor to the unified log, which makes it useless for
// figuring out why a drag never started.
NS_FORMAT_FUNCTION(1, 2) static inline void DTLog(NSString *format, ...) {
	if (!DTDebugEnabled())
		return;

	va_list args;
	va_start(args, format);
	NSString *line = [[NSString alloc] initWithFormat:format arguments:args];
	va_end(args);

	fprintf(stderr, "drag: %s\n", line.UTF8String);
	fflush(stderr);
}

NS_ASSUME_NONNULL_END
