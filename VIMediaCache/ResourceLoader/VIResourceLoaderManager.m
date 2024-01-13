//
//  VIResourceLoaderManager.m
//  VIMediaCacheDemo
//
//  Created by Vito on 4/21/16.
//  Copyright © 2016 Vito. All rights reserved.
//

#import "VIResourceLoaderManager.h"
#import "VIResourceLoader.h"

static NSString *kCacheScheme = @"VIMediaCache:";

@interface VIResourceLoaderManager () <VIResourceLoaderDelegate>

@property (nonatomic, strong) NSMutableDictionary<id<NSCoding>, VIResourceLoader *> *loaders;

@end

@implementation VIResourceLoaderManager

/*
 如果您使用 AVAssetResourceLoader 委托加载播放所需的媒体数据，应将 AVPlayer 的 automaticallyWaitsToMinimizeStalling 属性的值设置为 NO。当使用 AVAssetResourceLoader 委托加载媒体数据时，将 automaticallyWaitsToMinimizeStalling 的值保持为 YES（默认值）可能导致播放启动时间较长，而且从停顿中恢复较差，因为在 automaticallyWaitsToMinimizeStalling 的值为 YES 时，AVPlayer 提供的行为依赖于对媒体数据未来可用性的预测，而这些预测在通过客户控制的手段加载数据时无法按预期工作，使用 AVAssetResourceLoader 委托接口加载数据。
 */

/*
 automaticallyWaitsToMinimizeStalling
 
 在播放通过HTTP传递的媒体时，此属性用于确定播放器是否应自动延迟播放以最小化停顿。当此属性为true且播放器从暂停状态（速率为0.0）变为播放状态（速率> 0.0）时，播放器将尝试确定当前项目是否可以以当前指定的速率播放到其末尾。如果确定可能会遇到停顿，播放器的timeControlStatus值将更改为AVPlayer.TimeControlStatus.waitingToPlayAtSpecifiedRate，并且当最小化停顿的可能性时，播放将自动开始。在播放过程中，如果当前播放器项目的播放缓冲区用尽且播放停顿，将在最小化停顿的可能性时自动恢复播放。

 当需要对播放开始时间进行精确控制时（例如，如果正在使用setRate(_:time:atHostTime:)方法同步多个播放器实例），需要将此属性设置为false。如果此属性的值为false，并且播放缓冲区不为空，则将在请求时立即开始播放。如果播放缓冲区变空且播放停顿，播放器的timeControlStatus将切换为AVPlayer.TimeControlStatus.paused，并且播放速率将更改为0.0。

 在播放器的timeControlStatus为AVPlayer.TimeControlStatus.waitingToPlayAtSpecifiedRate且其reasonForWaitingToPlay为toMinimizeStalls时将此属性的值更改为false，将导致播放器立即尝试以指定速率播放。

 重要提示：
 对于与iOS 10.0及更高版本或macOS 10.12及更高版本链接的客户端（并在这些版本上运行），此属性的默认值为true。在先前的操作系统版本中不存在此属性，观察到的行为取决于所播放的媒体类型：

 HTTP Live Streaming（HLS）：在播放HLS媒体时，播放器的行为类似于automaticallyWaitsToMinimizeStalling为true。
 基于文件的媒体：在播放基于文件的媒体，包括逐步下载的内容时，播放器的行为类似于automaticallyWaitsToMinimizeStalling为false。
 您应该验证您的播放应用程序是否符合此新的默认自动等待行为。
 */
- (instancetype)init {
    self = [super init];
    if (self) {
        _loaders = [NSMutableDictionary dictionary];
    }
    return self;
}

- (void)cleanCache {
    [self.loaders removeAllObjects];
}

- (void)cancelLoaders {
    [self.loaders enumerateKeysAndObjectsUsingBlock:^(id<NSCoding>  _Nonnull key, VIResourceLoader * _Nonnull obj, BOOL * _Nonnull stop) {
        [obj cancel];
    }];
    [self.loaders removeAllObjects];
}

#pragma mark - AVAssetResourceLoaderDelegate

// 这里就是要实现的 Delegate 方法.
/*
 由于 AVPlayer 会触发分片下载的策略，request 请求会从 dataRequest 中获取请求的分片范围。
 因此，根据请求地址和请求分片，我们就可以创建自定义的网络请求。请求分片需要在 HTTP Header 中进行设置。
 */
- (BOOL)resourceLoader:(AVAssetResourceLoader *)resourceLoader
    shouldWaitForLoadingOfRequestedResource:(AVAssetResourceLoadingRequest *)loadingRequest  {
    NSURL *resourceURL = [loadingRequest.request URL];
    // 这里有一个懒加载的机制在. 
    if ([resourceURL.absoluteString hasPrefix:kCacheScheme]) {
        VIResourceLoader *loader = [self loaderForRequest:loadingRequest];
        if (!loader) {
            NSURL *originURL = nil;
            NSString *originStr = [resourceURL absoluteString];
            originStr = [originStr stringByReplacingOccurrencesOfString:kCacheScheme withString:@""];
            originURL = [NSURL URLWithString:originStr];
            loader = [[VIResourceLoader alloc] initWithURL:originURL];
            loader.delegate = self;
            NSString *key = [self keyForResourceLoaderWithURL:resourceURL];
            self.loaders[key] = loader;
        }
        [loader addRequest:loadingRequest];
        return YES;
    }
    
    return NO;
}

- (void)resourceLoader:(AVAssetResourceLoader *)resourceLoader didCancelLoadingRequest:(AVAssetResourceLoadingRequest *)loadingRequest {
    VIResourceLoader *loader = [self loaderForRequest:loadingRequest];
    [loader removeRequest:loadingRequest];
}

#pragma mark - VIResourceLoaderDelegate

- (void)resourceLoader:(VIResourceLoader *)resourceLoader didFailWithError:(NSError *)error {
    [resourceLoader cancel];
    if ([self.delegate respondsToSelector:@selector(resourceLoaderManagerLoadURL:didFailWithError:)]) {
        [self.delegate resourceLoaderManagerLoadURL:resourceLoader.url didFailWithError:error];
    }
}

#pragma mark - Helper

- (NSString *)keyForResourceLoaderWithURL:(NSURL *)requestURL {
    if([[requestURL absoluteString] hasPrefix:kCacheScheme]){
        NSString *s = requestURL.absoluteString;
        return s;
    }
    return nil;
}

- (VIResourceLoader *)loaderForRequest:(AVAssetResourceLoadingRequest *)request {
    NSString *requestKey = [self keyForResourceLoaderWithURL:request.request.URL];
    VIResourceLoader *loader = self.loaders[requestKey];
    return loader;
}

@end

@implementation VIResourceLoaderManager (Convenient)

+ (NSURL *)assetURLWithURL:(NSURL *)url {
    if (!url) {
        return nil;
    }

    // 为原本的 URL, 增加了固定的自定义的 scheme.
    NSURL *assetURL = [NSURL URLWithString:[kCacheScheme stringByAppendingString:[url absoluteString]]];
    return assetURL;
}

- (AVPlayerItem *)playerItemWithURL:(NSURL *)url {
    NSURL *assetURL = [VIResourceLoaderManager assetURLWithURL:url];
    AVURLAsset *urlAsset = [AVURLAsset URLAssetWithURL:assetURL options:nil];
    [urlAsset.resourceLoader setDelegate:self queue:dispatch_get_main_queue()];
    AVPlayerItem *playerItem = [AVPlayerItem playerItemWithAsset:urlAsset];
    if ([playerItem respondsToSelector:@selector(setCanUseNetworkResourcesForLiveStreamingWhilePaused:)]) {
        /*
         For live streaming content, the player item may need to use extra networking and power resources to keep playback state up to date when paused. For example, when this property is set to true, the seekableTimeRanges property will be periodically updated to reflect the current state of the live stream.
         To minimize power usage, avoid setting this property to true when you do not need playback state to stay up to date while paused.
         
         对于实时流媒体内容，播放器项可能需要使用额外的网络和电源资源，以保持在暂停时播放状态的最新信息。例如，当将此属性设置为 true 时，seekableTimeRanges 属性将定期更新，以反映实时流的当前状态。

         为了最小化电源消耗，在不需要在暂停时保持播放状态最新的情况下，避免将此属性设置为 true。
         */
        playerItem.canUseNetworkResourcesForLiveStreamingWhilePaused = YES;
    }
    return playerItem;
}

@end
