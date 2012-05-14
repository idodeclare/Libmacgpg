//
//  GPGTaskOperation.h
//  Libmacgpg
//
//  Created by Chris Fraire on 5/13/12.
//  Copyright (c) 2012 Chris Fraire. All rights reserved.
//

#import <Foundation/Foundation.h>

@class GPGTask, LPXTTask;

@interface GPGTaskOperation : NSOperation {
    GPGTask *parentTask;
    LPXTTask *gpgTask;
    NSOperationQueue *queue;
    NSException *exception;
}

@property (readonly) NSException *operationException;
@property (readonly) NSOperationQueue *queue;

+ taskFor:(GPGTask *)gtask lpxtTask:(LPXTTask *)ltask;
- initFor:(GPGTask *)gtask lpxtTask:(LPXTTask *)ltask;

@end
