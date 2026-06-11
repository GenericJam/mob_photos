/* mob_photos_nif — iOS photo/video picker tier-1 plugin NIF (Objective-C).
 *
 * Extracted from mob-core ios/mob_nif.m (the "Photo library picker" section,
 * mob_nif.m:2423-2515): PHPickerViewController (iOS 14+, runs out of process —
 * no permission needed). Self-contained — core's mob_send2 / mob_root_vc are
 * private statics, so this ships its own (pho_send2 / pho_root_vc). Compiled
 * as ObjC (-fobjc-arc) via the plugin objc-NIF path (manifest lang: :objc).
 *
 * Delivered message shapes (exact core parity, mob_nif.m:2437 + 2490-2492):
 *   cancelled -> {photos, cancelled}
 *   picked    -> {photos, picked, [#{path => binary, type => image|video}]}
 * Note: iOS items carry only path + type (type as an atom, NOT a string);
 * core never added width/height on iOS even though the Android JSON path
 * carries them (as 0) — preserved as-is.
 */
#import <Foundation/Foundation.h>
#import <PhotosUI/PhotosUI.h>
#import <UIKit/UIKit.h>
#include <erl_nif.h>

// Self-contained {atom, atom} send (core's mob_send2 is a private static).
static void pho_send2(const ErlNifPid *pid, const char *a1, const char *a2) {
  ErlNifEnv *e = enif_alloc_env();
  ERL_NIF_TERM msg = enif_make_tuple2(e, enif_make_atom(e, a1), enif_make_atom(e, a2));
  enif_send(NULL, (ErlNifPid *)pid, e, msg);
  enif_free_env(e);
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

// ── Photo library picker ──────────────────────────────────────────────────

@interface MobPhotosDelegate : NSObject <PHPickerViewControllerDelegate>
@property(nonatomic) ErlNifPid pid;
@property(nonatomic) int maxItems;
@end

static MobPhotosDelegate *g_photos_delegate = nil;

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
                                          @synchronized(items) {
                                              [items addObject:@{
                                                  @"path" : tmp,
                                                  @"type" : isVideo ? @"video" : @"image"
                                              }];
                                          }
                                      }
                                      dispatch_group_leave(grp);
                                    }];
      }
      dispatch_group_notify(grp, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        ErlNifEnv *e = enif_alloc_env();
        ERL_NIF_TERM list = enif_make_list(e, 0);
        for (NSDictionary *item in items.reverseObjectEnumerator) {
            const char *path = [item[@"path"] UTF8String];
            const char *type = [item[@"type"] UTF8String];
            ErlNifBinary pbin;
            enif_alloc_binary(strlen(path), &pbin);
            memcpy(pbin.data, path, strlen(path));
            ERL_NIF_TERM keys[2] = {enif_make_atom(e, "path"), enif_make_atom(e, "type")};
            ERL_NIF_TERM vals[2] = {enif_make_binary(e, &pbin), enif_make_atom(e, type)};
            ERL_NIF_TERM map;
            enif_make_map_from_arrays(e, keys, vals, 2, &map);
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

// ── Registration ──────────────────────────────────────────────────────────
// No load callback needed (unlike mob_camera, which registers a permission
// handler at load) — the picker requires no runtime permission.

static ErlNifFunc nif_funcs[] = {
    {"photos_pick", 2, nif_photos_pick, 0},
};

ERL_NIF_INIT(mob_photos_nif, nif_funcs, NULL, NULL, NULL, NULL)
