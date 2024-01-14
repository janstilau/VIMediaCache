#import "VIMediaCacheWorker.h"
#import "VICacheAction.h"
#import "VICacheManager.h"

@import UIKit;

static NSInteger const kPackageLength = 512 * 1024; // 512 kb per package
static NSString *kMCMediaCacheResponseKey = @"kMCMediaCacheResponseKey";
static NSString *VIMediaCacheErrorDoamin = @"com.vimediacache";

@interface VIMediaCacheWorker ()

@property (nonatomic, strong) NSFileHandle *readFileHandle;
@property (nonatomic, strong) NSFileHandle *writeFileHandle;
@property (nonatomic, strong, readwrite) NSError *setupError;
@property (nonatomic, copy) NSString *filePath;
@property (nonatomic, strong) VICacheConfiguration *internalCacheConfiguration;

@property (nonatomic) long long currentOffset;

@property (nonatomic, strong) NSDate *startWriteDate;
@property (nonatomic) float writeBytes;
@property (nonatomic) BOOL writting;

@end

@implementation VIMediaCacheWorker

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self save];
    [_readFileHandle closeFile];
    [_writeFileHandle closeFile];
}

- (instancetype)initWithURL:(NSURL *)url {
    self = [super init];
    if (self) {
        NSString *path = [VICacheManager cachedFilePathForURL:url];
        NSFileManager *fileManager = [NSFileManager defaultManager];
        _filePath = path;
        NSError *error;
        NSString *cacheFolder = [path stringByDeletingLastPathComponent];
        if (![fileManager fileExistsAtPath:cacheFolder]) {
            [fileManager createDirectoryAtPath:cacheFolder
                   withIntermediateDirectories:YES
                                    attributes:nil
                                         error:&error];
        }
        
        if (!error) {
            if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
                [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
            }
            NSURL *fileURL = [NSURL fileURLWithPath:path];
            _readFileHandle = [NSFileHandle fileHandleForReadingFromURL:fileURL error:&error];
            if (!error) {
                _writeFileHandle = [NSFileHandle fileHandleForWritingToURL:fileURL error:&error];
                _internalCacheConfiguration = [VICacheConfiguration configurationWithFilePath:path];
                _internalCacheConfiguration.url = url;
            }
        }
        
        _setupError = error;
    }
    return self;
}

- (VICacheConfiguration *)cacheConfiguration {
    return self.internalCacheConfiguration;
}

// 这个时候, writeFileHandle 已经和最终视频的文件大小一致了.
// 所以使用文件 seek 然后进行覆盖是没有问题的.
- (void)cacheData:(NSData *)data
         forRange:(NSRange)range error:(NSError **)error {
    @synchronized(self.writeFileHandle) {
        @try {
            [self.writeFileHandle seekToFileOffset:range.location];
            [self.writeFileHandle writeData:data];
            self.writeBytes += data.length;
            
            // 文件的修改, 和 JSON 的修改是同步的. 所以这里其实是由两份数据. config 里面, 存储了当前的已经缓存了的信息.
            [self.internalCacheConfiguration addCacheFragment:range];
        } @catch (NSException *exception) {
            NSLog(@"write to file error");
            *error = [NSError errorWithDomain:exception.name code:123 userInfo:@{NSLocalizedDescriptionKey: exception.reason, @"exception": exception}];
        }
    }
}

// 这里的 range, 一定是在 config 类里面读取出来的.
// 否则, 按照这个类的设计, 是不会或者不应该直接到文件里面读取数据的.
- (NSData *)cachedDataForRange:(NSRange)range
                         error:(NSError **)error {
    @synchronized(self.readFileHandle) {
        @try {
            [self.readFileHandle seekToFileOffset:range.location];
            NSData *data = [self.readFileHandle readDataOfLength:range.length]; // 空数据也会返回，所以如果 range 错误，会导致播放失效
            return data;
        } @catch (NSException *exception) {
            NSLog(@"read cached data error %@",exception);
            *error = [NSError errorWithDomain:exception.name code:123 userInfo:@{NSLocalizedDescriptionKey: exception.reason, @"exception": exception}];
        }
    }
    return nil;
}

/*
 这个类的核心功能, 根据已经缓存了的数据, 将 range 分割为需要网络下载的部分, 以及已经缓存了的部分
 返回的 action, 直接是通过文件读取数据, 或者需要触发网络下载.
 所以得操作, 都是异步的.
 */
- (NSArray<VICacheAction *> *)cachedDataActionsForRange:(NSRange)range {
    NSArray *cachedFragments = [self.internalCacheConfiguration cacheFragments];
    NSMutableArray *actions = [NSMutableArray array];
    
    if (range.location == NSNotFound) {
        return [actions copy];
    }
    NSInteger endOffset = range.location + range.length;
    // Delete header and footer not in range
    [cachedFragments enumerateObjectsUsingBlock:^(NSValue * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
        NSRange fragmentRange = obj.rangeValue;
        NSRange intersectionRange = NSIntersectionRange(range, fragmentRange);
        if (intersectionRange.length > 0) {
            NSInteger package = intersectionRange.length / kPackageLength;
            for (NSInteger i = 0; i <= package; i++) {
                VICacheAction *action = [VICacheAction new];
                action.actionType = VICacheAtionTypeLocal;
                
                NSInteger offset = i * kPackageLength;
                NSInteger offsetLocation = intersectionRange.location + offset;
                NSInteger maxLocation = intersectionRange.location + intersectionRange.length;
                NSInteger length = (offsetLocation + kPackageLength) > maxLocation ? (maxLocation - offsetLocation) : kPackageLength;
                action.range = NSMakeRange(offsetLocation, length);
                
                [actions addObject:action];
            }
        } else if (fragmentRange.location >= endOffset) {
            *stop = YES;
        }
    }];
    
    if (actions.count == 0) {
        VICacheAction *action = [VICacheAction new];
        action.actionType = VICacheAtionTypeRemote;
        action.range = range;
        [actions addObject:action];
    } else {
        // Add remote fragments
        NSMutableArray *localRemoteActions = [NSMutableArray array];
        [actions enumerateObjectsUsingBlock:^(VICacheAction * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
            NSRange actionRange = obj.range;
            if (idx == 0) {
                if (range.location < actionRange.location) {
                    VICacheAction *action = [VICacheAction new];
                    action.actionType = VICacheAtionTypeRemote;
                    action.range = NSMakeRange(range.location, actionRange.location - range.location);
                    [localRemoteActions addObject:action];
                }
                [localRemoteActions addObject:obj];
            } else {
                VICacheAction *lastAction = [localRemoteActions lastObject];
                NSInteger lastOffset = lastAction.range.location + lastAction.range.length;
                if (actionRange.location > lastOffset) {
                    VICacheAction *action = [VICacheAction new];
                    action.actionType = VICacheAtionTypeRemote;
                    action.range = NSMakeRange(lastOffset, actionRange.location - lastOffset);
                    [localRemoteActions addObject:action];
                }
                [localRemoteActions addObject:obj];
            }
            
            if (idx == actions.count - 1) {
                NSInteger localEndOffset = actionRange.location + actionRange.length;
                if (endOffset > localEndOffset) {
                    VICacheAction *action = [VICacheAction new];
                    action.actionType = VICacheAtionTypeRemote;
                    action.range = NSMakeRange(localEndOffset, endOffset - localEndOffset);
                    [localRemoteActions addObject:action];
                }
            }
        }];
        
        actions = localRemoteActions;
    }
    
    return [actions copy];
}

- (void)setContentInfo:(VIContentInfo *)contentInfo error:(NSError **)error {
    self.internalCacheConfiguration.contentInfo = contentInfo;
    @try {
        // 这个类库的问题可能就是在这里, 缓存的文件, 还没有下载, 就扩张到了那个大小了.
        [self.writeFileHandle truncateFileAtOffset:contentInfo.contentLength];
        [self.writeFileHandle synchronizeFile];
    } @catch (NSException *exception) {
        NSLog(@"read cached data error %@", exception);
        *error = [NSError errorWithDomain:exception.name code:123 userInfo:@{NSLocalizedDescriptionKey: exception.reason, @"exception": exception}];
    }
}

- (void)save {
    @synchronized (self.writeFileHandle) {
        /*
         Summary

         Causes all in-memory data and attributes of the file represented by the handle to write to permanent storage.

         - (void)synchronizeFile;

         Programs that require the file to always be in a known state should call this method. An invocation of this method doesn’t return until memory is flushed.
         Important
         This method raises NSFileHandleOperationException if called on a file handle representing a pipe or socket, if the file descriptor is closed, or if the operation failed.
         */
        [self.writeFileHandle synchronizeFile];
        [self.internalCacheConfiguration save];
    }
}

- (void)startWritting {
    if (!self.writting) {
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationDidEnterBackground:) name:UIApplicationDidEnterBackgroundNotification object:nil];
    }
    self.writting = YES;
    self.startWriteDate = [NSDate date];
    self.writeBytes = 0;
}

- (void)finishWritting {
    if (self.writting) {
        self.writting = NO;
        [[NSNotificationCenter defaultCenter] removeObserver:self];
        NSTimeInterval time = [[NSDate date] timeIntervalSinceDate:self.startWriteDate];
        [self.internalCacheConfiguration addDownloadedBytes:self.writeBytes spent:time];
    }
}

#pragma mark - Notification

- (void)applicationDidEnterBackground:(NSNotification *)notification {
    [self save];
}

@end
