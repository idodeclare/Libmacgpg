/*
 Copyright © Lukas Pitschl, 2011
 
 Diese Datei ist Teil von Libmacgpg.
 
 Libmacgpg ist freie Software. Sie können es unter den Bedingungen 
 der GNU General Public License, wie von der Free Software Foundation 
 veröffentlicht, weitergeben und/oder modifizieren, entweder gemäß 
 Version 3 der Lizenz oder (nach Ihrer Option) jeder späteren Version.
 
 Die Veröffentlichung von Libmacgpg erfolgt in der Hoffnung, daß es Ihnen 
 von Nutzen sein wird, aber ohne irgendeine Garantie, sogar ohne die implizite 
 Garantie der Marktreife oder der Verwendbarkeit für einen bestimmten Zweck. 
 Details finden Sie in der GNU General Public License.
 
 Sie sollten ein Exemplar der GNU General Public License zusammen mit diesem 
 Programm erhalten haben. Falls nicht, siehe <http://www.gnu.org/licenses/>.
*/

#import "LPXTTask.h"
#import "GPGGlobals.h"
// Includes definition for _NSGetEnviron
#import <crt_externs.h>
#import <libgen.h>
#import <spawn.h>

typedef struct {
    int fd;
    int dupfd;
} lpxttask_fd;

@interface LPXTTask ()

- (void)inheritPipe:(NSPipe *)pipe mode:(int)mode dup:(int)dupfd name:(NSString *)name addIfExists:(BOOL)add;
- (void)_performParentTask;
@property BOOL cancelled;

@end

@implementation LPXTTask
@synthesize arguments=_arguments, currentDirectoryPath=_currentDirectoryPath, 
            environment=_environment, launchPath=_launchPath, 
            processIdentifier=_processIdentifier, standardError=_standardError,
            standardInput=_standardInput, standardOutput=_standardOutput,
            terminationStatus=_terminationStatus, parentTask=_parentTask,
			cancelled=_cancelled;

- (id)init
{
    self = [super init];
    if(self != nil) {
        _inheritedPipesMap = [[NSMutableDictionary alloc] init];
    }
    return self;
}

/*
 Undocumented behavior of -[NSFileManager fileSystemRepresentationWithPath:]
 is to raise an exception when passed an empty string.  Since this is called by
 -[NSString fileSystemRepresentation], use CF.  rdar://problem/9565599
 
 https://bitbucket.org/jfh/machg/issue/244/p1d3-crash-during-view-differences
 
 Have to copy all -[NSString fileSystemRepresentation] pointers to avoid garbage collection
 issues with -fileSystemRepresentation, anyway.  How tedious compared to -autorelease...
 
 http://lists.apple.com/archives/objc-language/2011/Mar/msg00122.html
 */
static char *__BDSKCopyFileSystemRepresentation(NSString *str)
{
    if (nil == str) return NULL;
    
    CFIndex len = CFStringGetMaximumSizeOfFileSystemRepresentation((CFStringRef)str);
    char *cstr = NSZoneCalloc(NSDefaultMallocZone(), len, sizeof(char));
    if (CFStringGetFileSystemRepresentation((CFStringRef)str, cstr, len) == FALSE) {
        NSZoneFree(NSDefaultMallocZone(), cstr);
        cstr = NULL;
    }
    return cstr;
}

- (void)launchAndWait {
    // This launch method is partly taken from BDSKTask.
    const NSUInteger argCount = [_arguments count];
    char *workingDir = __BDSKCopyFileSystemRepresentation(_currentDirectoryPath);
    
    // fill with pointers to copied C strings
    char **args = NSZoneCalloc([self zone], (argCount + 2), sizeof(char *));
    NSUInteger i;
    char *spawnPath = __BDSKCopyFileSystemRepresentation(_launchPath);
    args[0] = strdup(basename(spawnPath));
    for (i = 0; i < argCount; i++) {
        args[i + 1] = __BDSKCopyFileSystemRepresentation([_arguments objectAtIndex:i]);
    }
    args[argCount + 1] = NULL;
    
    char ***nsEnvironment = (char ***)_NSGetEnviron();
    char **env = *nsEnvironment;
    
    NSDictionary *environment = [self environment];
    if (environment) {
        // fill with pointers to copied C strings
        env = NSZoneCalloc([self zone], [environment count] + 1, sizeof(char *));
        NSString *key;
        NSUInteger envIndex = 0;
        for (key in environment) {
            env[envIndex++] = __BDSKCopyFileSystemRepresentation([NSString stringWithFormat:@"%@=%@", key, [environment objectForKey:key]]);        
        }
        env[envIndex] = NULL;
    }
    // Add the stdin, stdout and stderr to the inherited pipes, so all of them can be
    // processed together.
    if([_standardInput isKindOfClass:[NSPipe class]])
        [self inheritPipe:_standardInput mode:O_WRONLY dup:0 name:@"stdin"];
    if([_standardOutput isKindOfClass:[NSPipe class]])
        [self inheritPipe:_standardOutput mode:O_RDONLY dup:1 name:@"stdout"];
    if([_standardError isKindOfClass:[NSPipe class]])
        [self inheritPipe:_standardError mode:O_RDONLY dup:2 name:@"stderr"];
    
    // File descriptors to close in the parent process.
    NSMutableSet *closeInParent = [NSMutableSet set];
    
    posix_spawn_file_actions_t file_actions;
    posix_spawn_file_actions_init(&file_actions);
    
    posix_spawnattr_t spawn_attr;
    posix_spawnattr_init(&spawn_attr);
    posix_spawnattr_setflags(&spawn_attr, POSIX_SPAWN_SETPGROUP);

    NSMutableArray *allPipeList = [[NSMutableArray alloc] init];
    for(id key in _inheritedPipesMap) {
        NSArray *pipeList = [_inheritedPipesMap objectForKey:key];
        [allPipeList addObjectsFromArray:pipeList];
    }
    [allPipeList sortUsingComparator:^NSComparisonResult(id a, id b){
        NSNumber *adupfd = [a valueForKey:@"dupfd"];
        NSNumber *bdupfd = [b valueForKey:@"dupfd"];
        if([adupfd isLessThan:bdupfd])
            return NSOrderedAscending;
        else if([bdupfd isLessThan:adupfd])
            return NSOrderedDescending;
        else
            return NSOrderedSame;
    }];
    NSMutableSet *inheritFdSet = [NSMutableSet set];
    for (NSDictionary *pipeInfo in allPipeList) {            
        NSPipe *tmpPipe = (NSPipe *)[pipeInfo valueForKey:@"pipeobj"];
        int othfd, fd, dupfd;
        // The mode value of the pipe decides what should happen with the
        // pipe fd of the parent. Opposite with the fd of the child.
        if([[pipeInfo valueForKey:@"mode"] intValue] == O_RDONLY) {
            [closeInParent addObject:[tmpPipe fileHandleForWriting]];
            othfd = [[tmpPipe fileHandleForReading] fileDescriptor];
            fd = [[tmpPipe fileHandleForWriting] fileDescriptor];
        }
        else {
            [closeInParent addObject:[tmpPipe fileHandleForReading]];
            othfd = [[tmpPipe fileHandleForWriting] fileDescriptor];
            fd = [[tmpPipe fileHandleForReading] fileDescriptor];
        }
        dupfd = [[pipeInfo valueForKey:@"dupfd"] intValue];
        posix_spawn_file_actions_addclose(&file_actions, othfd);
        posix_spawn_file_actions_adddup2(&file_actions, fd, dupfd);
        [inheritFdSet addObject:[NSNumber numberWithInt:othfd]];
        [inheritFdSet addObject:[NSNumber numberWithInt:fd]];
        [inheritFdSet addObject:[NSNumber numberWithInt:dupfd]];
    }
    [allPipeList release];

    // To find the fds wich are acutally open, it would be possibe to
    // read /dev/fd entries. But not sure if that's a problem, so let's
    // use BDSKTask's version.
    rlim_t maxOpenFiles = OPEN_MAX;
    struct rlimit openFileLimit;
    if (getrlimit(RLIMIT_NOFILE, &openFileLimit) == 0)
        maxOpenFiles = openFileLimit.rlim_cur;

    // in Lion, easier to set POSIX_SPAWN_CLOEXEC_DEFAULT and use 
    // posix_spawn_file_actions_addinherit_np as necessary, but 
    // not yet available in 10.6
    for (int j = 0; j < maxOpenFiles; j++) {
        BOOL do_close = ![inheritFdSet containsObject:[NSNumber numberWithInt:j]];
        if(do_close) {
            int fgetfd;
            if ((fgetfd = fcntl(j, F_GETFD)) != -1 && !(fgetfd & FD_CLOEXEC))
                posix_spawn_file_actions_addclose(&file_actions, j);
        }
    }

    // Possibly change the working dir.
    char *cwd = NULL;
    if (workingDir) {
        cwd = getcwd(NULL, 0);
        chdir(workingDir);
    }

    pid_t spawned_pid;
    if (posix_spawnp(&spawned_pid, spawnPath, &file_actions, &spawn_attr, args, env) != 0) {
        // parent: error
        perror("posix_spawnp failed!");
        _terminationStatus = 2;
    }
    else {
        // This is the parent.
        _processIdentifier = spawned_pid;
        
        // Close the fd's in the parent.
        [closeInParent makeObjectsPerformSelector:@selector(closeFile)];
        
        // Run the task setup to run in the parent.
        [self _performParentTask];
        
        // Wait for the gpg process to finish.
        int retval, stat_loc;
        while ((retval = waitpid(_processIdentifier, &stat_loc, 0)) != _processIdentifier) {
            int e = errno;
            if (retval != -1 || e != EINTR) {
                GPGDebugLog(@"waitpid loop: %i errno: %i, %s", retval, e, strerror(e));
            }
        }
        _terminationStatus = WEXITSTATUS(stat_loc);
    }
    
    /*
     Free all the copied C strings.  Don't modify the base pointer of args or env, since we have to
     free those too!
     */
    free(workingDir);
    free(spawnPath);
    char **freePtr = args;
    while (NULL != *freePtr) { 
        free(*freePtr++);
    }
    
    NSZoneFree(NSZoneFromPointer(args), args);
    if (*nsEnvironment != env) {
        freePtr = env;
        while (NULL != *freePtr) { 
            free(*freePtr++);
        }
        NSZoneFree(NSZoneFromPointer(env), env);
    }

    posix_spawn_file_actions_destroy(&file_actions);
    posix_spawnattr_destroy(&spawn_attr);

    if (cwd) {
        chdir(cwd);
        free(cwd);
    }
}

- (void)_performParentTask {
    if(_parentTask != nil) {
        _parentTask();
    }
}

/**
 All the magic happens in here.
 Each pipe add is not closed, when the children is initialized.
 Fd's not added are automatically closed.
 
 If there's already a pipe registered under the given name, one of 2 things happens:
 1.) addIfExists is set to true -> add the pipe under the given name.
 2.) addIfExists is set to NO -> don't add the pipe and raise an error!
 */
- (void)inheritPipe:(NSPipe *)pipe mode:(int)mode dup:(int)dupfd name:(NSString *)name addIfExists:(BOOL)addIfExists {
    // Create a dictionary holding additional information about the pipe.
    // This info is used later to close and dup the file descriptor which
    // is used by either parent or child.
    NSMutableDictionary *pipeInfo = [[NSMutableDictionary alloc] initWithObjectsAndKeys:
                                     [NSNumber numberWithInt:mode], @"mode",
                                     [NSNumber numberWithInt:dupfd], @"dupfd", 
                                     pipe, @"pipeobj", nil];
    // The pipe info is add to the pipe maps.
    // If a pipe already exists under that name, it's added to the list of pipes the
    // name is referring to.
    NSMutableArray *pipeList = (NSMutableArray *)[_inheritedPipesMap valueForKey:name];
    if([pipeList count] && !addIfExists) {
        [pipeInfo release];
        @throw [NSException exceptionWithName:@"LPXTTask" 
                                       reason:[NSString stringWithFormat:@"A pipe is already registered under the name %@",
                                               name]
                                     userInfo:nil];
        return;
    }
    NSMutableArray *allocArray = nil;
    if(![pipeList count]) {
        allocArray = [[NSMutableArray alloc] init];
        pipeList = allocArray;
    }

    [pipeList addObject:pipeInfo];
    [pipeInfo release];
    // Add the pipe list, if this is the first pipe to be added.
    if([pipeList count] == 1)
        [_inheritedPipesMap setValue:pipeList forKey:name];
    [allocArray release];
}

- (void)inheritPipe:(NSPipe *)pipe mode:(int)mode dup:(int)dupfd name:(NSString *)name {
    // Raise an error if the pipe already exists.
    [self inheritPipe:pipe mode:mode dup:dupfd name:name addIfExists:NO];
}

- (void)inheritPipes:(NSArray *)pipes mode:(int)mode dups:(NSArray *)dupfds name:(NSString *)name {
    NSAssert([pipes count] == [dupfds count], @"Number of pipes and fds to duplicate not matching!");
    
    for(int i = 0; i < [pipes count]; i++) {
        [self inheritPipe:[pipes objectAtIndex:i] mode:mode dup:[[dupfds objectAtIndex:i] intValue] name:name addIfExists:YES];
    }
}

- (NSArray *)inheritedPipesWithName:(NSString *)name {
    // Find the pipe info matching the given name.
    NSMutableArray *pipeList = [NSMutableArray array];
    NSArray *pipesForName = [_inheritedPipesMap objectForKey:name];
    for(NSDictionary *pipeInfo in pipesForName) {
		[pipeList addObject:[pipeInfo valueForKey:@"pipeobj"]];
	}
    return pipeList;
}

- (NSPipe *)inheritedPipeWithName:(NSString *)name {
    NSArray *pipeList = [self inheritedPipesWithName:name];
    // If there's no pipe registered for that name, raise an error.
    if(![pipeList count] && pipeList != nil) {
        @throw [NSException exceptionWithName:@"NoPipeRegisteredUnderNameException" 
                                       reason:[NSString stringWithFormat:@"There's no pipe registered for name: %@", name] 
                                     userInfo:nil];
        
    }
    return [pipeList objectAtIndex:0];
}

- (void)removeInheritedPipeWithName:(NSString *)name {
    [_inheritedPipesMap setValue:nil forKey:name];
}

- (void)dealloc {
    [_arguments release];
    [_currentDirectoryPath release];
    [_environment release];
    [_launchPath release];
    [_standardError release];
    [_standardInput release];
    [_standardOutput release];
    [_parentTask release];
    [_inheritedPipesMap release];
    [super dealloc];
}

- (void)closePipes {
    // Close all pipes, otherwise SIGTERM is ignored it seems.
    for(id key in _inheritedPipesMap) {
        NSArray *pipeList = [_inheritedPipesMap objectForKey:key];
        for(NSDictionary *pipeInfo in pipeList) {            
            NSPipe *pipe = [pipeInfo valueForKey:@"pipeobj"];
            @try {
                [[pipe fileHandleForReading] closeFile];
            }
            @catch (NSException *e) {
                // Simply ignore.
            }
            @try {
                [[pipe fileHandleForWriting] closeFile];
            }
            @catch (NSException *e) {
                // Simply ignore.
            }
        }
    }
}

- (void)cancel {
	self.cancelled = YES;
	if (self.processIdentifier > 0) {
        // Close all pipes, otherwise SIGTERM is ignored it seems.
        [self closePipes];
		kill(self.processIdentifier, SIGTERM);
	}
}

@end
