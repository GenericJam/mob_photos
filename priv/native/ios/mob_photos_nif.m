/* mob_photos_nif — iOS photo/video picker, library enumeration and thumbnail
 * tier-1 plugin NIF (Objective-C).
 *
 * Extracted from mob-core ios/mob_nif.m (the "Photo library picker" section,
 * mob_nif.m:2423-2515): PHPickerViewController (iOS 14+, runs out of process —
 * the picker needs no permission). Self-contained — core's mob_send2 /
 * mob_root_vc are private statics, so this ships its own (pho_send2 /
 * pho_root_vc). Compiled as ObjC (-fobjc-arc) via the plugin objc-NIF path
 * (manifest lang: :objc).
 *
 * This plugin also owns the :media runtime-permission capability (mirrors how
 * mob_camera owns :camera): the handler self-registers with core's permission
 * registry at NIF load (mob_register_permission_handler, an exported core
 * symbol linked into the same static binary) and requests PHPhotoLibrary
 * read-write authorization (limited access counts as granted).
 *
 * Delivered message shapes:
 *   cancelled -> {photos, cancelled}
 *   picked    -> {photos, picked, [#{path, type => image|video, name, size,
 *                                   width, height}]}
 *                (core parity: path + type, type as an atom; name/size and,
 *                for images, upright width/height are additive)
 *   listed    -> {mob_file_result, <<"media">>, <<"listed">>, Json}
 *                — the same envelope the Android bridge sends; core's
 *                Mob.Screen decodes it into {media, listed, Items}.
 *
 * photo_thumbnail/1 is a synchronous dirty-IO NIF: JSON request in, JSON
 * reply out (decoded by MobPhotos.decode_thumbnail_result/1).
 */
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <Photos/Photos.h>
#import <PhotosUI/PhotosUI.h>
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <erl_nif.h>
#include <stdio.h>

/* Defined in core mob's ios/mob_nif.m, linked into the same static binary. */
extern void mob_register_permission_handler(const char *cap, void (*fn)(ErlNifPid));

// Self-contained {atom, atom} send (core's mob_send2 is a private static).
static void pho_send2(const ErlNifPid *pid, const char *a1, const char *a2) {
  ErlNifEnv *e = enif_alloc_env();
  ERL_NIF_TERM msg = enif_make_tuple2(e, enif_make_atom(e, a1), enif_make_atom(e, a2));
  enif_send(NULL, (ErlNifPid *)pid, e, msg);
  enif_free_env(e);
}

static ERL_NIF_TERM pho_make_binary(ErlNifEnv *e, const void *data, size_t len) {
  ErlNifBinary bin;
  enif_alloc_binary(len, &bin);
  if (len > 0)
    memcpy(bin.data, data, len);
  return enif_make_binary(e, &bin);
}

static ERL_NIF_TERM pho_make_string(ErlNifEnv *e, NSString *s) {
  const char *c = [s UTF8String] ?: "";
  return pho_make_binary(e, c, strlen(c));
}

// Root view controller for presenting the picker (core's mob_root_vc is a
// private static).
static UIViewController *pho_root_vc(void) {
  for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
    if ([scene isKindOfClass:[UIWindowScene class]]) {
      UIWindowScene *ws = (UIWindowScene *)scene;
      UIWindow *w = ws.keyWindow ?: ws.windows.firstObject;
      if (w.rootViewController)
        return w.rootViewController;
    }
  }
  return nil;
}

static BOOL pho_library_readable(void) {
  PHAuthorizationStatus s = [PHPhotoLibrary authorizationStatusForAccessLevel:PHAccessLevelReadWrite];
  return s == PHAuthorizationStatusAuthorized || s == PHAuthorizationStatusLimited;
}

static NSString *pho_mime_for_uti(NSString *uti) {
  if (uti.length == 0)
    return nil;
  return [UTType typeWithIdentifier:uti].preferredMIMEType;
}

// ── :media permission (registered with core's registry at NIF load) ───────
static void pho_send_permission(ErlNifPid pid, const char *status) {
  ErlNifEnv *e = enif_alloc_env();
  ERL_NIF_TERM msg = enif_make_tuple3(e, enif_make_atom(e, "permission"),
                                      enif_make_atom(e, "media"), enif_make_atom(e, status));
  enif_send(NULL, &pid, e, msg);
  enif_free_env(e);
}

static void mob_photos_request_permission(ErlNifPid pid) {
  [PHPhotoLibrary
      requestAuthorizationForAccessLevel:PHAccessLevelReadWrite
                                 handler:^(PHAuthorizationStatus status) {
                                   BOOL ok = (status == PHAuthorizationStatusAuthorized ||
                                              status == PHAuthorizationStatusLimited);
                                   pho_send_permission(pid, ok ? "granted" : "denied");
                                 }];
}

// ── Photo library picker ──────────────────────────────────────────────────

@interface MobPhotosDelegate : NSObject <PHPickerViewControllerDelegate>
@property(nonatomic) ErlNifPid pid;
@property(nonatomic) int maxItems;
@end

static MobPhotosDelegate *g_photos_delegate = nil;

// Upright pixel size from the image header (no decode). NO for non-images.
static BOOL pho_image_size(NSURL *url, long *w, long *h) {
  CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
  if (!src)
    return NO;
  NSDictionary *props =
      CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(src, 0, NULL));
  CFRelease(src);
  NSNumber *pw = props[(NSString *)kCGImagePropertyPixelWidth];
  NSNumber *ph = props[(NSString *)kCGImagePropertyPixelHeight];
  if (!pw || !ph)
    return NO;
  int orientation = [props[(NSString *)kCGImagePropertyOrientation] intValue];
  BOOL swap = orientation >= 5 && orientation <= 8;
  *w = swap ? ph.longValue : pw.longValue;
  *h = swap ? pw.longValue : ph.longValue;
  return YES;
}

@implementation MobPhotosDelegate
- (void)picker:(PHPickerViewController *)picker
    didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
    if (results.count == 0) {
        pho_send2(&_pid, "photos", "cancelled");
        g_photos_delegate = nil;
        return;
    }
    ErlNifPid p = self.pid;
    g_photos_delegate = nil;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
      dispatch_group_t grp = dispatch_group_create();
      NSMutableArray *items = [NSMutableArray array];
      for (PHPickerResult *result in results) {
          dispatch_group_enter(grp);
          BOOL isVideo = [result.itemProvider hasItemConformingToTypeIdentifier:@"public.movie"];
          NSString *typeId = isVideo ? @"public.movie" : @"public.image";
          NSString *suggested = result.itemProvider.suggestedName;
          [result.itemProvider
              loadFileRepresentationForTypeIdentifier:typeId
                                    completionHandler:^(NSURL *url, NSError *err) {
                                      if (url) {
                                          NSString *ext = isVideo ? @"mp4" : @"jpg";
                                          NSString *tmp = [NSTemporaryDirectory()
                                              stringByAppendingPathComponent:
                                                  [NSString
                                                      stringWithFormat:@"mob_pick_%@.%@",
                                                                       [NSUUID UUID].UUIDString,
                                                                       ext]];
                                          [[NSFileManager defaultManager]
                                              copyItemAtURL:url
                                                      toURL:[NSURL fileURLWithPath:tmp]
                                                      error:nil];
                                          NSMutableDictionary *item = [@{
                                              @"path" : tmp,
                                              @"type" : isVideo ? @"video" : @"image",
                                              @"name" : suggested ?: url.lastPathComponent,
                                          } mutableCopy];
                                          NSDictionary *attrs = [[NSFileManager defaultManager]
                                              attributesOfItemAtPath:tmp
                                                               error:nil];
                                          item[@"size"] = @([attrs fileSize]);
                                          long w = 0, h = 0;
                                          if (!isVideo &&
                                              pho_image_size([NSURL fileURLWithPath:tmp], &w, &h)) {
                                              item[@"width"] = @(w);
                                              item[@"height"] = @(h);
                                          }
                                          @synchronized(items) {
                                              [items addObject:item];
                                          }
                                      }
                                      dispatch_group_leave(grp);
                                    }];
      }
      dispatch_group_notify(grp, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        ErlNifEnv *e = enif_alloc_env();
        ERL_NIF_TERM list = enif_make_list(e, 0);
        for (NSDictionary *item in items.reverseObjectEnumerator) {
            ERL_NIF_TERM keys[6];
            ERL_NIF_TERM vals[6];
            unsigned n = 0;
            keys[n] = enif_make_atom(e, "path");
            vals[n++] = pho_make_string(e, item[@"path"]);
            keys[n] = enif_make_atom(e, "type");
            vals[n++] = enif_make_atom(e, [item[@"type"] UTF8String]);
            keys[n] = enif_make_atom(e, "name");
            vals[n++] = pho_make_string(e, item[@"name"]);
            keys[n] = enif_make_atom(e, "size");
            vals[n++] = enif_make_uint64(e, [item[@"size"] unsignedLongLongValue]);
            if (item[@"width"]) {
                keys[n] = enif_make_atom(e, "width");
                vals[n++] = enif_make_long(e, [item[@"width"] longValue]);
                keys[n] = enif_make_atom(e, "height");
                vals[n++] = enif_make_long(e, [item[@"height"] longValue]);
            }
            ERL_NIF_TERM map;
            enif_make_map_from_arrays(e, keys, vals, n, &map);
            list = enif_make_list_cell(e, map, list);
        }
        ERL_NIF_TERM msg =
            enif_make_tuple3(e, enif_make_atom(e, "photos"), enif_make_atom(e, "picked"), list);
        enif_send(NULL, &p, e, msg);
        enif_free_env(e);
      });
    });
}
@end

// PARITY: core's nif_photos_pick (mob_nif.m:2499-2501) reads only argv[0]
// (max) and ignores argv[1] (types) — the PHPicker shows images + videos
// regardless. Preserved exactly; arity stays 2 to match the .erl stub.
static ERL_NIF_TERM nif_photos_pick(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    int max = 1;
    enif_get_int(env, argv[0], &max);
    ErlNifPid pid;
    enif_self(env, &pid);
    dispatch_async(dispatch_get_main_queue(), ^{
      PHPickerConfiguration *cfg = [[PHPickerConfiguration alloc] init];
      cfg.selectionLimit = max;
      PHPickerViewController *vc = [[PHPickerViewController alloc] initWithConfiguration:cfg];
      g_photos_delegate = [[MobPhotosDelegate alloc] init];
      g_photos_delegate.pid = pid;
      g_photos_delegate.maxItems = max;
      vc.delegate = g_photos_delegate;
      [pho_root_vc() presentViewController:vc animated:YES completion:nil];
    });
    return enif_make_atom(env, "ok");
}

// ── Library enumeration (PHAsset) ─────────────────────────────────────────
// Async: fetches on a background queue and delivers
// {mob_file_result, <<"media">>, <<"listed">>, Json} — byte-for-byte the
// Android envelope, so core's Mob.Screen decoder turns it into the same
// {media, listed, Items}. Newest first by creationDate. Unknown values are
// left out of the item (a JSON null would decode to the atom :null).
// Without photo-library access an empty list is delivered, like Android.

static NSDictionary *pho_list_item(PHAsset *asset) {
  NSMutableDictionary *o = [NSMutableDictionary dictionary];
  o[@"uri"] = [@"ph://" stringByAppendingString:asset.localIdentifier];
  BOOL isVideo = asset.mediaType == PHAssetMediaTypeVideo;
  o[@"type"] = isVideo ? @"video" : @"image";
  NSTimeInterval created = asset.creationDate.timeIntervalSince1970;
  if (asset.creationDate) {
    o[@"date_added"] = @((long long)created);
    o[@"date_taken"] = @((long long)(created * 1000.0));
  } else {
    o[@"date_added"] = @0;
  }
  if (asset.pixelWidth > 0 && asset.pixelHeight > 0) {
    o[@"width"] = @(asset.pixelWidth);
    o[@"height"] = @(asset.pixelHeight);
  }
  // The primary resource carries the original filename, UTI and size.
  PHAssetResource *primary = nil;
  for (PHAssetResource *r in [PHAssetResource assetResourcesForAsset:asset]) {
    if (r.type == PHAssetResourceTypePhoto || r.type == PHAssetResourceTypeVideo) {
      primary = r;
      break;
    }
    if (!primary)
      primary = r;
  }
  o[@"display_name"] = primary.originalFilename ?: @"";
  o[@"mime_type"] = pho_mime_for_uti(primary.uniformTypeIdentifier) ?: @"";
  // fileSize is not public API on PHAssetResource but has been KVC-readable
  // since iOS 10; it is cheap (no I/O). Leave size out if it ever goes away.
  if (primary) {
    @try {
      id size = [primary valueForKey:@"fileSize"];
      if ([size isKindOfClass:[NSNumber class]] && [size longLongValue] > 0)
        o[@"size"] = size;
    } @catch (NSException *ex) {
    }
  }
  return o;
}

static void pho_deliver_listed(ErlNifPid pid, NSData *json) {
  ErlNifEnv *e = enif_alloc_env();
  ERL_NIF_TERM msg = enif_make_tuple4(e, enif_make_atom(e, "mob_file_result"),
                                      pho_make_binary(e, "media", 5),
                                      pho_make_binary(e, "listed", 6),
                                      pho_make_binary(e, json.bytes, json.length));
  enif_send(NULL, &pid, e, msg);
  enif_free_env(e);
}

// Arity 1 (opts JSON {"type":"image"|"video"|"all","limit":N}) matches the
// .erl stub.
static ERL_NIF_TERM nif_media_list(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    ErlNifBinary bin;
    if (!enif_inspect_binary(env, argv[0], &bin) && !enif_inspect_iolist_as_binary(env, argv[0], &bin))
        return enif_make_badarg(env);
    NSData *optsData = [NSData dataWithBytes:bin.data length:bin.size];
    ErlNifPid pid;
    enif_self(env, &pid);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      @autoreleasepool {
        NSDictionary *opts = [NSJSONSerialization JSONObjectWithData:optsData options:0 error:nil];
        if (![opts isKindOfClass:[NSDictionary class]])
            opts = @{};
        NSString *type = [opts[@"type"] isKindOfClass:[NSString class]] ? opts[@"type"] : @"all";
        long limit = [opts[@"limit"] isKindOfClass:[NSNumber class]] ? [opts[@"limit"] longValue] : 200;
        NSMutableArray *out = [NSMutableArray array];
        if (pho_library_readable()) {
            PHFetchOptions *fo = [[PHFetchOptions alloc] init];
            fo.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:@"creationDate" ascending:NO] ];
            if ([type isEqualToString:@"image"])
                fo.predicate = [NSPredicate predicateWithFormat:@"mediaType == %d", PHAssetMediaTypeImage];
            else if ([type isEqualToString:@"video"])
                fo.predicate = [NSPredicate predicateWithFormat:@"mediaType == %d", PHAssetMediaTypeVideo];
            else
                fo.predicate = [NSPredicate predicateWithFormat:@"mediaType == %d || mediaType == %d",
                                                                PHAssetMediaTypeImage, PHAssetMediaTypeVideo];
            if (limit > 0)
                fo.fetchLimit = (NSUInteger)limit;
            PHFetchResult<PHAsset *> *assets = [PHAsset fetchAssetsWithOptions:fo];
            [assets enumerateObjectsUsingBlock:^(PHAsset *asset, NSUInteger idx, BOOL *stop) {
              @autoreleasepool {
                [out addObject:pho_list_item(asset)];
              }
            }];
        }
        NSData *json = [NSJSONSerialization dataWithJSONObject:out options:0 error:nil] ?: [@"[]" dataUsingEncoding:NSUTF8StringEncoding];
        pho_deliver_listed(pid, json);
      }
    });
    return enif_make_atom(env, "ok");
}

// ── Thumbnail (synchronous, dirty IO) ─────────────────────────────────────

static NSDictionary *pho_error(NSString *code) { return @{@"error" : code ?: @"unknown error"}; }

// FNV-1a: a stable cache-file name per request, so repeats overwrite.
static NSString *pho_request_hash(NSString *s) {
  uint64_t h = 1469598103934665603ULL;
  for (const unsigned char *p = (const unsigned char *)[s UTF8String]; *p; p++) {
    h ^= *p;
    h *= 1099511628211ULL;
  }
  return [NSString stringWithFormat:@"%016llx", h];
}

static NSString *pho_string(id v) {
  return [v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0 ? v : nil;
}

// Decode + downscale + write the JPEG; fills the reply with dimensions, MIME
// and the raw EXIF / GPS / TIFF fields MobPhotos.decode_thumbnail_result/1
// expects. Returns an error dictionary on failure.
static NSDictionary *pho_thumbnail_from_source(CGImageSourceRef src, NSString *cacheKey, long maxSize,
                                               int quality, NSMutableDictionary *reply) {
  CFStringRef uti = CGImageSourceGetType(src);
  if (!uti || CGImageSourceGetCount(src) == 0)
    return pho_error(@"unsupported");
  NSDictionary *props = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(src, 0, NULL));
  NSNumber *pw = props[(NSString *)kCGImagePropertyPixelWidth];
  NSNumber *ph = props[(NSString *)kCGImagePropertyPixelHeight];
  if (pw.longValue <= 0 || ph.longValue <= 0)
    return pho_error(@"unsupported");
  int orientation = [props[(NSString *)kCGImagePropertyOrientation] intValue];
  BOOL swap = orientation >= 5 && orientation <= 8;
  long longest = MAX(pw.longValue, ph.longValue);

  NSDictionary *thumbOpts = @{
    (NSString *)kCGImageSourceCreateThumbnailFromImageAlways : @YES,
    (NSString *)kCGImageSourceCreateThumbnailWithTransform : @YES,
    (NSString *)kCGImageSourceShouldCacheImmediately : @YES,
    (NSString *)kCGImageSourceThumbnailMaxPixelSize : @(MIN(maxSize, longest)),
  };
  CGImageRef thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, (__bridge CFDictionaryRef)thumbOpts);
  if (!thumb)
    return pho_error(@"unsupported");

  NSString *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
  [[NSFileManager defaultManager] createDirectoryAtPath:caches withIntermediateDirectories:YES attributes:nil error:nil];
  NSString *path = [caches stringByAppendingPathComponent:
                               [NSString stringWithFormat:@"mob_thumb_%@.jpg", pho_request_hash(cacheKey)]];
  NSString *tmp = [path stringByAppendingString:@".tmp"];
  CGImageDestinationRef dst = CGImageDestinationCreateWithURL(
      (__bridge CFURLRef)[NSURL fileURLWithPath:tmp], (__bridge CFStringRef)UTTypeJPEG.identifier, 1, NULL);
  if (!dst) {
    CGImageRelease(thumb);
    return pho_error([@"could not write " stringByAppendingString:path]);
  }
  NSDictionary *dstOpts = @{(NSString *)kCGImageDestinationLossyCompressionQuality : @(quality / 100.0)};
  CGImageDestinationAddImage(dst, thumb, (__bridge CFDictionaryRef)dstOpts);
  BOOL ok = CGImageDestinationFinalize(dst);
  CFRelease(dst);
  size_t tw = CGImageGetWidth(thumb), th = CGImageGetHeight(thumb);
  CGImageRelease(thumb);
  if (!ok || rename([tmp fileSystemRepresentation], [path fileSystemRepresentation]) != 0) {
    unlink([tmp fileSystemRepresentation]);
    return pho_error([@"could not write " stringByAppendingString:path]);
  }

  reply[@"path"] = path;
  reply[@"width"] = @(tw);
  reply[@"height"] = @(th);
  reply[@"orig_width"] = swap ? ph : pw;
  reply[@"orig_height"] = swap ? pw : ph;
  if (!reply[@"mime"]) {
    NSString *mime = pho_mime_for_uti((__bridge NSString *)uti);
    if (mime)
      reply[@"mime"] = mime;
  }

  NSDictionary *exif = props[(NSString *)kCGImagePropertyExifDictionary];
  NSString *dt = pho_string(exif[(NSString *)kCGImagePropertyExifDateTimeOriginal])
                     ?: pho_string(exif[(NSString *)kCGImagePropertyExifDateTimeDigitized]);
  if (dt)
    reply[@"exif_datetime"] = dt;
  NSString *offset = pho_string(exif[(NSString *)kCGImagePropertyExifOffsetTimeOriginal]);
  if (offset)
    reply[@"exif_offset"] = offset;

  // An asset's PHAsset.location (set by the caller) wins over EXIF GPS.
  NSDictionary *gps = props[(NSString *)kCGImagePropertyGPSDictionary];
  NSNumber *lat = gps[(NSString *)kCGImagePropertyGPSLatitude];
  NSNumber *lon = gps[(NSString *)kCGImagePropertyGPSLongitude];
  if (!reply[@"latitude"] && [lat isKindOfClass:[NSNumber class]] && [lon isKindOfClass:[NSNumber class]]) {
    double la = lat.doubleValue, lo = lon.doubleValue;
    if ([pho_string(gps[(NSString *)kCGImagePropertyGPSLatitudeRef]) isEqualToString:@"S"])
      la = -la;
    if ([pho_string(gps[(NSString *)kCGImagePropertyGPSLongitudeRef]) isEqualToString:@"W"])
      lo = -lo;
    reply[@"latitude"] = @(la);
    reply[@"longitude"] = @(lo);
    NSNumber *alt = gps[(NSString *)kCGImagePropertyGPSAltitude];
    if ([alt isKindOfClass:[NSNumber class]]) {
      double a = alt.doubleValue;
      if ([gps[(NSString *)kCGImagePropertyGPSAltitudeRef] intValue] == 1)
        a = -a;
      reply[@"altitude"] = @(a);
    }
  }

  NSDictionary *tiff = props[(NSString *)kCGImagePropertyTIFFDictionary];
  NSString *make = pho_string(tiff[(NSString *)kCGImagePropertyTIFFMake]);
  NSString *model = pho_string(tiff[(NSString *)kCGImagePropertyTIFFModel]);
  if (make)
    reply[@"make"] = make;
  if (model)
    reply[@"model"] = model;
  return reply;
}

static NSDictionary *pho_thumbnail_file(NSString *path, NSString *cacheKey, long maxSize, int quality) {
  NSFileManager *fm = [NSFileManager defaultManager];
  if (![fm fileExistsAtPath:path])
    return pho_error(@"not_found");
  if (![fm isReadableFileAtPath:path])
    return pho_error(@"permission");
  CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], NULL);
  if (!src)
    return pho_error(@"unsupported");
  NSMutableDictionary *reply = [NSMutableDictionary dictionary];
  NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];
  if (attrs)
    reply[@"size"] = @([attrs fileSize]);
  NSDictionary *res = pho_thumbnail_from_source(src, cacheKey, maxSize, quality, reply);
  CFRelease(src);
  return res;
}

static NSDictionary *pho_thumbnail_asset(NSString *localId, NSString *cacheKey, long maxSize, int quality) {
  if (!pho_library_readable())
    return pho_error(@"permission");
  PHAsset *asset = [PHAsset fetchAssetsWithLocalIdentifiers:@[ localId ] options:nil].firstObject;
  if (!asset)
    return pho_error(@"not_found");
  if (asset.mediaType != PHAssetMediaTypeImage)
    return pho_error(@"unsupported");

  // The original bytes (not a rendered UIImage), so ImageIO sees the EXIF.
  // Synchronous is fine here: this runs on a dirty scheduler thread, never
  // the main thread. iCloud-only originals are downloaded.
  PHImageRequestOptions *ro = [[PHImageRequestOptions alloc] init];
  ro.synchronous = YES;
  ro.networkAccessAllowed = YES;
  ro.version = PHImageRequestOptionsVersionCurrent;
  ro.deliveryMode = PHImageRequestOptionsDeliveryModeHighQualityFormat;
  __block NSData *data = nil;
  __block NSString *dataUTI = nil;
  __block NSError *err = nil;
  [[PHImageManager defaultManager]
      requestImageDataAndOrientationForAsset:asset
                                     options:ro
                               resultHandler:^(NSData *d, NSString *uti, CGImagePropertyOrientation o,
                                               NSDictionary *info) {
                                 data = d;
                                 dataUTI = uti;
                                 err = info[PHImageErrorKey];
                               }];
  if (!data)
    return pho_error(err ? err.localizedDescription : @"could not load the asset's image data");

  NSMutableDictionary *reply = [NSMutableDictionary dictionary];
  reply[@"size"] = @(data.length);
  NSString *mime = pho_mime_for_uti(dataUTI);
  if (mime)
    reply[@"mime"] = mime;
  if (asset.creationDate)
    reply[@"date_taken_ms"] = @((long long)(asset.creationDate.timeIntervalSince1970 * 1000.0));
  // Plain property reads (message sends) — no CoreLocation symbol to link.
  CLLocation *loc = asset.location;
  if (loc && loc.horizontalAccuracy >= 0) {
    reply[@"latitude"] = @(loc.coordinate.latitude);
    reply[@"longitude"] = @(loc.coordinate.longitude);
    if (loc.verticalAccuracy > 0)
      reply[@"altitude"] = @(loc.altitude);
  }
  CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
  if (!src)
    return pho_error(@"unsupported");
  NSDictionary *res = pho_thumbnail_from_source(src, cacheKey, maxSize, quality, reply);
  CFRelease(src);
  return res;
}

// photo_thumbnail(RequestJson) -> ReplyJson. Flagged ERL_NIF_DIRTY_JOB_IO_BOUND
// in nif_funcs: it decodes a full-size image (and may wait on Photos), so it
// must never run on a normal scheduler.
static ERL_NIF_TERM nif_photo_thumbnail(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    ErlNifBinary bin;
    if (!enif_inspect_binary(env, argv[0], &bin) && !enif_inspect_iolist_as_binary(env, argv[0], &bin))
        return enif_make_badarg(env);
    @autoreleasepool {
        NSDictionary *req = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:bin.data length:bin.size]
                                                            options:0
                                                              error:nil];
        NSDictionary *reply;
        if (![req isKindOfClass:[NSDictionary class]]) {
            reply = pho_error(@"invalid thumbnail request");
        } else {
            NSString *kind = pho_string(req[@"kind"]) ?: @"";
            NSString *source = pho_string(req[@"source"]) ?: @"";
            long maxSize = MAX(1L, [req[@"max_size"] longValue]);
            int quality = MIN(100, MAX(1, [req[@"quality"] intValue]));
            NSString *key = [NSString stringWithFormat:@"%@\n%@\n%ld\n%d", kind, source, maxSize, quality];
            if ([kind isEqualToString:@"file"])
                reply = pho_thumbnail_file(source, key, maxSize, quality);
            else if ([kind isEqualToString:@"asset"])
                reply = pho_thumbnail_asset(source, key, maxSize, quality);
            else if ([kind isEqualToString:@"content"])
                reply = pho_error(@"content:// URIs are Android-only; on iOS pass a file path or a ph:// asset id");
            else
                reply = pho_error([@"unknown source kind: " stringByAppendingString:kind]);
        }
        NSData *json = [NSJSONSerialization dataWithJSONObject:reply options:0 error:nil];
        if (!json)
            json = [@"{\"error\":\"could not encode the thumbnail reply\"}" dataUsingEncoding:NSUTF8StringEncoding];
        return pho_make_binary(env, json.bytes, json.length);
    }
}

// ── Registration ──────────────────────────────────────────────────────────
// load callback registers the :media permission handler with core's registry
// (the picker itself needs no permission, but enumeration does).
static int pho_load(ErlNifEnv *env, void **priv_data, ERL_NIF_TERM load_info) {
    (void)env;
    (void)priv_data;
    (void)load_info;
    mob_register_permission_handler("media", mob_photos_request_permission);
    return 0;
}

static ErlNifFunc nif_funcs[] = {
    {"photos_pick", 2, nif_photos_pick, 0},
    {"media_list", 1, nif_media_list, 0},
    {"photo_thumbnail", 1, nif_photo_thumbnail, ERL_NIF_DIRTY_JOB_IO_BOUND},
};

ERL_NIF_INIT(mob_photos_nif, nif_funcs, pho_load, NULL, NULL, NULL)
