/*
 Copyright © Lukas Pitschl, 2013
 
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

#import <Foundation/Foundation.h>

typedef void (^lpxt_task_t)(void);

@interface LPXTTask : NSObject {
    NSArray *arguments;
    NSString *launchPath;
    
    int processIdentifier;
    int terminationStatus;
    
    lpxt_task_t parentTask;

@private
    NSMutableArray *inheritedPipes;
    NSMutableDictionary *inheritedPipesMap;
	
}

- (void)launchAndWait;
- (void)inheritPipeWithMode:(int)mode dup:(int)dupfd name:(NSString *)name;
- (void)inheritPipesWithMode:(int)mode dups:(NSArray *)dupfds name:(NSString *)name;
- (NSPipe *)inheritedPipeWithName:(NSString *)name;
- (NSArray *)inheritedPipesWithName:(NSString *)name;
- (void)removeInheritedPipeWithName:(NSString *)name;

@property (nonatomic, retain) NSArray *arguments;
@property (nonatomic, copy) NSString *launchPath;
@property (nonatomic, readonly) int terminationStatus;
@property (nonatomic, copy) lpxt_task_t parentTask;

- (void)cancel;

@end
