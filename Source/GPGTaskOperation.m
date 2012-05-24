//
//  GPGTaskOperation.m
//  Libmacgpg
//
//  Created by Chris Fraire on 5/13/12.
//  Copyright (c) 2012 Chris Fraire. All rights reserved.
//

#import "GPGTaskOperation.h"
#import "GPGTask.h"
#import "LPXTTask.h"

@implementation GPGTaskOperation

@synthesize queue;
@synthesize operationException = exception;

+ (id)taskFor:(GPGTask *)gtask lpxtTask:(LPXTTask *)ltask
{
    return [[[self alloc] initFor:gtask lpxtTask:ltask] autorelease];
}

- (id)initFor:(GPGTask *)gtask lpxtTask:(LPXTTask *)ltask
{
    if (self = [super init]) {
        parentTask = [gtask retain];
        gpgTask = [ltask retain];
        queue = [[NSOperationQueue alloc] init];
    }
    return self;
}

- (void)dealloc
{
    [parentTask release];
    [gpgTask release];
    [queue release];
    [exception release];
    [super dealloc];
}

- (void)main
{
    if (!queue) {
        [exception release];
        exception = [[NSException alloc] initWithName:@"ApplicationException" 
                                               reason:@"Cannot run twice" userInfo:nil];
        return;
    }
    
    // The data is written to the pipe as soon as gpg issues the status
    // BEGIN_ENCRYPTION or BEGIN_SIGNING. See processStatus.
    // When we want to encrypt or sign, the data can't be written before the 
    // BEGIN_ENCRYPTION or BEGIN_SIGNING status was issued, BUT
    // in every other case, gpg stalls till it received the data to decrypt.
    // So in that case, the data actually has to be written as the very first thing.
    
    NSArray *options = [NSArray arrayWithObjects:@"--encrypt", @"--sign", @"--clearsign", @"--detach-sign", @"--symmetric", @"-e", @"-s", @"-b", @"-c", nil];

    // threads will synchronize on the exContainer
    NSMutableArray *exContainer = [NSMutableArray array];
    
    if([gpgTask.arguments firstObjectCommonWithArray:options] == nil) {
        [queue addOperation:[[[NSInvocationOperation alloc] 
                              initWithTarget:parentTask selector:@selector(_writeInputData:) object:exContainer] autorelease]];
    }
    // Add each job to the collector group.
    [queue addOperation:[[[NSInvocationOperation alloc] 
                          initWithTarget:parentTask selector:@selector(_readStdout:) object:exContainer] autorelease]];
    [queue addOperation:[[[NSInvocationOperation alloc] 
                          initWithTarget:parentTask selector:@selector(_readStderr:) object:exContainer] autorelease]];
    if(parentTask.getAttributeData) {
        [queue addOperation:[[[NSInvocationOperation alloc] 
                              initWithTarget:parentTask selector:@selector(_readAttributes:) object:exContainer] autorelease]];
    }
    
    // Handle the status data. This is an important one.
    [queue addOperation:[[[NSInvocationOperation alloc] 
                          initWithTarget:parentTask selector:@selector(_handleStatus:) object:exContainer] autorelease]];
    
    // Wait for the jobs to finish.
    [queue waitUntilAllOperationsAreFinished];
    [exception release];
    exception = [[exContainer lastObject] retain];

    [queue release];
    queue = nil;
}

@end
