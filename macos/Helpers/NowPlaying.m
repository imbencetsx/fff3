// Streams every Now Playing player on this Mac as JSON lines on stdout.
// macOS only answers MediaRemote for Apple-signed processes, so the app runs this
// inside /usr/bin/perl (see NowPlayingSource.swift) instead of loading it itself.
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <objc/message.h>

// Declared so ARC sees these as initializers and balances alloc and init.
@protocol Fff3MediaRemoteInit
- (id)initWithPlayerPath:(id)path;
- (id)initWithOrigin:(id)origin client:(id)client player:(id)player;
@end

typedef void (*Clients)(dispatch_queue_t, void (^)(CFArrayRef));
typedef void (*Register)(dispatch_queue_t);

static Clients nowPlayingClients;
static Class requestClass, playerPathClass;
static NSArray *lastSent;
// Per player: what its cover is keyed on, the cover itself, and the cover last sent.
static NSMutableDictionary<NSString *, NSString *> *artworkKeys;
static NSMutableDictionary<NSString *, NSData *> *artworks;
static NSMutableDictionary<NSString *, NSData *> *sentArtworks;
static BOOL checking, checkAgain;
static unsigned long checkRound;

static void writeLine(NSDictionary *event) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:event options:0 error:nil];
    if (!json) return;
    fwrite(json.bytes, 1, json.length, stdout);
    fputc('\n', stdout);
    if (fflush(stdout) != 0) exit(0);
}

static NSString *string(id value) {
    return [value isKindOfClass:NSString.class] ? value : @"";
}

static NSString *clientText(id client, SEL selector) {
    return string([client respondsToSelector:selector] ? [client performSelector:selector] : nil);
}

static id requestFor(id path) {
    return [[requestClass alloc] initWithPlayerPath:path];
}

static void check(void);

static void finishCheck(void) {
    checking = NO;
    if (checkAgain) { checkAgain = NO; check(); }
}

// Change notifications come in bursts, so one check runs at a time and repeats once if needed.
static void check(void) {
    if (checking) { checkAgain = YES; return; }
    checking = YES;
    unsigned long round = ++checkRound;
    // A request that never answers must not stop every later check.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (checking && checkRound == round) finishCheck();
    });
    // Every app with a Now Playing session, not only the "active" players: that list
    // drops music playing in the background while a video holds Control Centre.
    nowPlayingClients(dispatch_get_main_queue(), ^(CFArrayRef list) {
        if (checkRound != round) return;
        id origin = [NSClassFromString(@"MROrigin") performSelector:@selector(localOrigin)];
        id activePath = [requestClass performSelector:@selector(localNowPlayingPlayerPath)];
        id active = [activePath respondsToSelector:@selector(client)] ? [activePath performSelector:@selector(client)] : nil;
        NSMutableArray<NSMutableDictionary *> *players = [NSMutableArray array];
        dispatch_group_t group = dispatch_group_create();
        NSArray *clients = (__bridge NSArray *)list;
        for (id client in [clients isKindOfClass:NSArray.class] ? clients : @[]) {
            // A nil player means the app's default player, as Control Centre uses.
            id path = [[playerPathClass alloc] initWithOrigin:origin client:client player:nil];
            NSString *playerID = [client description];
            NSMutableDictionary *player = [@{
                @"id": playerID,
                @"app": clientText(client, @selector(displayName)),
                @"bundle": clientText(client, @selector(bundleIdentifier)),
                // Web content plays from a helper process; its parent names the browser.
                @"parent": clientText(client, @selector(parentApplicationBundleIdentifier)),
                @"active": [playerID isEqualToString:[active description]] ? @YES : @NO,
                @"playing": @NO,
            } mutableCopy];
            [players addObject:player];
            id request = requestFor(path);

            dispatch_group_enter(group);
            ((void (*)(id, SEL, dispatch_queue_t, void (^)(BOOL, id)))objc_msgSend)(
                request, @selector(requestIsPlayingOnQueue:completion:), dispatch_get_main_queue(), ^(BOOL playing, id error) {
                    player[@"playing"] = playing ? @YES : @NO;
                    dispatch_group_leave(group);
                });

            dispatch_group_enter(group);
            ((void (*)(id, SEL, dispatch_queue_t, void (^)(id, id)))objc_msgSend)(
                request, @selector(requestNowPlayingInfoOnQueue:completion:), dispatch_get_main_queue(), ^(id raw, id error) {
                    NSDictionary *info = [raw isKindOfClass:NSDictionary.class] ? raw : @{};
                    NSString *title = string(info[@"kMRMediaRemoteNowPlayingInfoTitle"]);
                    player[@"title"] = title;
                    player[@"artist"] = string(info[@"kMRMediaRemoteNowPlayingInfoArtist"]);
                    player[@"album"] = string(info[@"kMRMediaRemoteNowPlayingInfoAlbum"]);
                    player[@"mediaType"] = string(info[@"kMRMediaRemoteNowPlayingInfoMediaType"]);
                    player[@"strictMediaType"] = string(info[@"kMRMediaRemoteNowPlayingInfoStrictMediaType"]);
                    NSString *identifier = string(info[@"kMRMediaRemoteNowPlayingInfoArtworkIdentifier"]);
                    BOOL hasArtwork = identifier.length > 0 || string(info[@"kMRMediaRemoteNowPlayingInfoArtworkMIMEType"]).length > 0;
                    player[@"hasArtwork"] = hasArtwork ? @YES : @NO;
                    // Fetch the cover when the song changes, and again until one arrives:
                    // a fetch can come back empty or never answer.
                    NSString *key = identifier.length > 0 ? identifier
                        : [NSString stringWithFormat:@"%@\n%@\n%@", title, player[@"artist"], player[@"album"]];
                    if (hasArtwork && (![artworkKeys[playerID] isEqualToString:key] || !artworks[playerID])) {
                        artworkKeys[playerID] = key;
                        [artworks removeObjectForKey:playerID];
                        dispatch_group_enter(group);
                        ((void (*)(id, SEL, dispatch_queue_t, void (^)(id, id)))objc_msgSend)(
                            request, @selector(requestNowPlayingItemArtworkOnQueue:completion:), dispatch_get_main_queue(), ^(id artwork, id error) {
                                id data = [artwork respondsToSelector:@selector(imageData)] ? [artwork performSelector:@selector(imageData)] : nil;
                                if ([data isKindOfClass:NSData.class] && [data length] > 0 && [artworkKeys[playerID] isEqualToString:key]) {
                                    artworks[playerID] = data;
                                }
                                dispatch_group_leave(group);
                            });
                    }
                    dispatch_group_leave(group);
                });
        }
        dispatch_group_notify(group, dispatch_get_main_queue(), ^{
            if (checkRound != round) return;
            NSMutableSet *live = [NSMutableSet set];
            NSMutableArray *withArtwork = [NSMutableArray array];
            BOOL newArtwork = NO;
            for (NSMutableDictionary *player in players) {
                NSString *playerID = player[@"id"];
                [live addObject:playerID];
                NSData *data = artworks[playerID];
                NSMutableDictionary *sent = [player mutableCopy];
                if (data && ![data isEqualToData:sentArtworks[playerID]]) {
                    sent[@"artwork"] = [data base64EncodedStringWithOptions:0];
                    newArtwork = YES;
                }
                [withArtwork addObject:sent];
            }
            for (NSString *playerID in artworkKeys.allKeys) {
                if (![live containsObject:playerID]) {
                    [artworkKeys removeObjectForKey:playerID];
                    [artworks removeObjectForKey:playerID];
                    [sentArtworks removeObjectForKey:playerID];
                }
            }
            if (newArtwork || ![players isEqualToArray:lastSent]) {
                writeLine(@{@"players": withArtwork});
                lastSent = players;
                for (NSString *playerID in live) {
                    if (artworks[playerID]) sentArtworks[playerID] = artworks[playerID];
                }
            }
            finishCheck();
        });
    });
}

// Perl calls this as an XSUB; it never returns.
void fff3_now_playing(void *perl, void *cv) {
    void *mr = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    nowPlayingClients = (Clients)dlsym(mr, "MRMediaRemoteGetNowPlayingClients");
    Register registerForNotifications = (Register)dlsym(mr, "MRMediaRemoteRegisterForNowPlayingNotifications");
    requestClass = NSClassFromString(@"MRNowPlayingRequest");
    playerPathClass = NSClassFromString(@"MRPlayerPath");
    if (!nowPlayingClients || !playerPathClass || !registerForNotifications || !requestClass || !NSClassFromString(@"MROrigin")) {
        fprintf(stderr, "MediaRemote is not available\n");
        exit(2);
    }
    artworkKeys = [NSMutableDictionary dictionary];
    artworks = [NSMutableDictionary dictionary];
    sentArtworks = [NSMutableDictionary dictionary];

    // The app holds our stdin open; when it quits, stdin ends and so do we.
    dispatch_source_t input = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, STDIN_FILENO, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(input, ^{
        char buffer[256];
        if (read(STDIN_FILENO, buffer, sizeof buffer) <= 0) exit(0);
    });
    dispatch_resume(input);

    // Any MediaRemote change may concern a player in the background, so all of them trigger a check.
    registerForNotifications(dispatch_get_main_queue());
    [NSNotificationCenter.defaultCenter addObserverForName:nil object:nil queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification *note) {
        if ([note.name hasPrefix:@"kMRMediaRemote"] || [note.name hasPrefix:@"MRMediaRemote"]) check();
    }];
    // Background players do not always post changes, so look again every second.
    [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer) { check(); }];
    check();
    CFRunLoopRun();
}
