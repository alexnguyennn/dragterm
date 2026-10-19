//
//  DTDraggingSourceView.h
//  drag
//
//  Created by Nate Weaver on 2019-06-07.
//  Copyright © 2019 Nate Weaver/Derailer. All rights reserved.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface DTDraggingSourceView : NSView <NSDraggingSource>

@property (nonatomic, copy) NSArray<NSURL *> *URLs;

@property (nonatomic) CGFloat iconSize;

/// YES once a dragging session has been created, so the caller can stop steering the
/// window: from that point the pointer belongs to the drag.
@property (nonatomic, readonly) BOOL dragSessionStarted;

@end

NS_ASSUME_NONNULL_END
