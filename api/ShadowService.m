#import <HBLog.h>

#import <AppSupport/CPDistributedMessagingCenter.h>
#import <rocketbootstrap/rocketbootstrap.h>

#import "ShadowService.h"
#import "../apple_priv/NSTask.h"

@implementation ShadowService {
    NSCache* responseCache;
    NSString* dpkgPath;
    NSOperationQueue* opQueue;
    CPDistributedMessagingCenter* center;
}

- (BOOL)isPathRestricted_internal:(NSString *)path {
    if(!path || [path isEqualToString:@"/"] || [path isEqualToString:@""]) {
        return NO;
    }

    // Check response cache for given path.
    NSNumber* responseCachePath = [responseCache objectForKey:path];

    if(responseCachePath) {
        return [responseCachePath boolValue];
    }

    // Recurse call into parent directories.
    NSString* pathParent = [path stringByDeletingLastPathComponent];

    if(![pathParent isEqualToString:@"/"]) {
        BOOL isParentPathRestricted = [self isPathRestricted_internal:pathParent];

        if(isParentPathRestricted) {
            return YES;
        }
    }

    BOOL restricted = NO;
    
    // Call dpkg to see if file is part of any installed packages on the system.
    NSTask* task = [NSTask new];
    NSPipe* stdoutPipe = [NSPipe new];

    [task setLaunchPath:dpkgPath];
    [task setArguments:@[@"--no-pager", @"-S", path]];
    [task setStandardOutput:stdoutPipe];
    [task launch];
    [task waitUntilExit];

    HBLogDebug(@"%@: %@", @"dpkg", path);

    if([task terminationStatus] == 0) {
        // Path found in dpkg database - exclude if base package is part of the package list.
        NSData* data = [[stdoutPipe fileHandleForReading] readDataToEndOfFile];
        NSString* output = [[NSString alloc] initWithData:data encoding:NSASCIIStringEncoding];
        NSArray* lines = [output componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];

        for(NSString* line in lines) {
            NSArray* line_split = [line componentsSeparatedByString:@": "];

            if([line_split count] == 2) {
                NSString* line_packages = line_split[0];

                if([line_packages hasPrefix:@"local diversion"]) {
                    continue;
                }

                NSString* line_path = line_split[1];
                NSArray* line_packages_split = [line_packages componentsSeparatedByString:@", "];

                BOOL exception = [line_packages_split containsObject:@"base"] || [line_packages_split containsObject:@"firmware-sbin"];

                if(!exception) {
                    NSArray* base_extra = @[
                        @"/Library/Application Support",
                        @"/usr/lib"
                    ];

                    if([base_extra containsObject:line_path]) {
                        exception = YES;
                    }
                }

                restricted = !exception;
                [responseCache setObject:@(restricted) forKey:line_path];
            }
        }
    }

    [responseCache setObject:@(restricted) forKey:path];
    return restricted;
}

- (NSArray*)getURLSchemes_internal {
    if([responseCache objectForKey:@"schemes"]) {
        return [responseCache objectForKey:@"schemes"];
    }

    NSMutableArray* schemes = [NSMutableArray new];

    NSTask* task = [NSTask new];
    NSPipe* stdoutPipe = [NSPipe new];

    [task setLaunchPath:dpkgPath];
    [task setArguments:@[@"--no-pager", @"-S", @"app/Info.plist"]];
    [task setStandardOutput:stdoutPipe];
    [task launch];
    [task waitUntilExit];

    if([task terminationStatus] == 0) {
        NSData* data = [[stdoutPipe fileHandleForReading] readDataToEndOfFile];
        NSString* output = [[NSString alloc] initWithData:data encoding:NSASCIIStringEncoding];

        NSCharacterSet* separator = [NSCharacterSet newlineCharacterSet];
        NSArray<NSString *>* lines = [output componentsSeparatedByCharactersInSet:separator];

        for(NSString* entry in lines) {
            NSArray<NSString *>* line = [entry componentsSeparatedByString:@": "];

            if([line count] == 2) {
                NSString* plistpath = [line objectAtIndex:1];

                if([plistpath hasSuffix:@"Info.plist"]) {
                    NSDictionary* plist = [NSDictionary dictionaryWithContentsOfFile:plistpath];

                    if(plist && plist[@"CFBundleURLTypes"]) {
                        for(NSDictionary* type in plist[@"CFBundleURLTypes"]) {
                            if(type[@"CFBundleURLSchemes"]) {
                                for(NSString* scheme in type[@"CFBundleURLSchemes"]) {
                                    [schemes addObject:scheme];
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    NSArray* schemes_ret = [schemes copy];
    [responseCache setObject:schemes_ret forKey:@"schemes"];
    return schemes_ret;
}

- (NSDictionary *)handleMessageNamed:(NSString *)name withUserInfo:(NSDictionary *)userInfo {
    if(!name) {
        return nil;
    }

    NSDictionary* response = nil;

    if([name isEqualToString:@"resolvePath"]) {
        if(!userInfo) {
            return nil;
        }

        NSString* rawPath = userInfo[@"path"];

        if(!rawPath) {
            return nil;
        }

        // Resolve and standardize path.
        NSString* path = [[rawPath stringByExpandingTildeInPath] stringByStandardizingPath];

        if([path hasPrefix:@"/private/var"] || [path hasPrefix:@"/private/etc"]) {
            NSMutableArray* pathComponents = [[path pathComponents] mutableCopy];
            [pathComponents removeObjectAtIndex:1];
            path = [NSString pathWithComponents:pathComponents];
        }

        if([path hasPrefix:@"/var/tmp"]) {
            NSMutableArray* pathComponents = [[path pathComponents] mutableCopy];
            [pathComponents removeObjectAtIndex:1];
            path = [NSString pathWithComponents:pathComponents];
        }

        response = @{
            @"path" : path
        };
    } else if([name isEqualToString:@"isPathRestricted"]) {
        if(!userInfo) {
            return nil;
        }
        
        NSString* path = userInfo[@"path"];

        if(!path || [path isEqualToString:@"/"] || [path isEqualToString:@""]) {
            return nil;
        }

        if(![path isAbsolutePath]) {
            HBLogDebug(@"%@: %@: %@", name, @"ignoring relative path", path);
            return nil;
        }

        if(![[NSFileManager defaultManager] fileExistsAtPath:path]) {
            return nil;
        }

        HBLogDebug(@"%@: %@", name, path);
        
        // Check if path is restricted.
        BOOL restricted = [self isPathRestricted_internal:path];

        response = @{
            @"restricted" : @(restricted)
        };
    } else if([name isEqualToString:@"getURLSchemes"]) {
        response = @{
            @"schemes" : [self getURLSchemes_internal]
        };
    }

    return response;
}

- (void)startService {
    NSArray* dpkgPaths = @[
        @"/usr/bin/dpkg-query",
        @"/var/jb/usr/bin/dpkg-query",
        @"/usr/local/bin/dpkg-query",
        @"/var/jb/usr/local/bin/dpkg-query"
    ];

    for(NSString* path in dpkgPaths) {
        if([[NSFileManager defaultManager] fileExistsAtPath:path]) {
            dpkgPath = path;
            break;
        }
    }

    if(center) {
        [center runServerOnCurrentThread];

        // Register messages.
        [center registerForMessageName:@"getVersions" target:self selector:@selector(handleMessageNamed:withUserInfo:)];
        [center registerForMessageName:@"isPathRestricted" target:self selector:@selector(handleMessageNamed:withUserInfo:)];
        [center registerForMessageName:@"getURLSchemes" target:self selector:@selector(handleMessageNamed:withUserInfo:)];
        [center registerForMessageName:@"resolvePath" target:self selector:@selector(handleMessageNamed:withUserInfo:)];

        rocketbootstrap_unlock(CPDMC_SERVICE_NAME);
    }
}

- (NSDictionary *)sendIPC:(NSString *)messageName withArgs:(NSDictionary *)args {
    if(!center) {
        return nil;
    }

    NSError* error = nil;
    NSDictionary* result = [center sendMessageAndReceiveReplyName:messageName userInfo:args error:&error];
    return error ? nil : result;
}

- (NSString *)resolvePath:(NSString *)path {
    if(!path) {
        return nil;
    }

    NSDictionary* response = [self sendIPC:@"resolvePath" withArgs:@{
        @"path" : path
    }];

    if(response) {
        path = response[@"path"];
    } else {
        path = [path stringByReplacingOccurrencesOfString:@"/./" withString:@"/"];
        path = [path stringByReplacingOccurrencesOfString:@"//" withString:@"/"];

        if([path hasPrefix:@"/private/var"] || [path hasPrefix:@"/private/etc"]) {
            NSMutableArray* pathComponents = [[path pathComponents] mutableCopy];
            [pathComponents removeObjectAtIndex:1];
            path = [NSString pathWithComponents:pathComponents];
        }

        if([path hasPrefix:@"/var/tmp"]) {
            NSMutableArray* pathComponents = [[path pathComponents] mutableCopy];
            [pathComponents removeObjectAtIndex:1];
            path = [NSString pathWithComponents:pathComponents];
        }
    }

    return path;
}

- (BOOL)isPathRestricted:(NSString *)path {
    if(!path || [path isEqualToString:@"/"] || [path isEqualToString:@""]) {
        return NO;
    }

    NSNumber* response_cached = [responseCache objectForKey:path];

    if(response_cached) {
        return [response_cached boolValue];
    }

    NSDictionary* response = [self sendIPC:@"isPathRestricted" withArgs:@{
        @"path" : path
    }];

    if(response) {
        [responseCache setObject:response[@"restricted"] forKey:path];
        return [response[@"restricted"] boolValue];
    }

    return NO;
}

- (NSArray*)getURLSchemes {
    NSDictionary* response = [self sendIPC:@"getURLSchemes" withArgs:nil];

    if(response) {
        return response[@"schemes"];
    }

    return @[@"cydia", @"sileo", @"zbra", @"filza"];
}

- (NSDictionary *)getVersions {
    return @{
        @"build_date" : [NSString stringWithFormat:@"%@ %@", @__DATE__, @__TIME__],
        @"bypass_version" : @BYPASS_VERSION,
        @"api_version" : @API_VERSION
    };
}

- (instancetype)init {
    if((self = [super init])) {
        responseCache = [NSCache new];
        opQueue = [NSOperationQueue new];

        center = [CPDistributedMessagingCenter centerNamed:@CPDMC_SERVICE_NAME];
        rocketbootstrap_distributedmessagingcenter_apply(center);
    }

    return self;
}
@end
