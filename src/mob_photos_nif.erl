%% mob_photos_nif — Erlang NIF module for the photo/video picker + MediaStore
%% enumeration tier-1 plugin.
%%
%% iOS: priv/native/ios/mob_photos_nif.m (Objective-C: PHPickerViewController,
%% iOS 14+, runs out of process so the picker needs no runtime permission; plus
%% the :media permission flow via PHPhotoLibrary). Android:
%% priv/native/jni/mob_photos_nif.zig bridging to the system Photo Picker
%% (PickVisualMedia / PickMultipleVisualMedia) AND MediaStore enumeration
%% (ContentResolver) via the io.mob.photos MobPhotosBridge Kotlin bridge. Both
%% register this module via ERL_NIF_INIT and are statically linked into the host
%% binary on device. On a host dev build neither is linked, so on_load tolerates
%% the failure and the NIFs fall back to nif_error until the native merge links
%% one.
-module(mob_photos_nif).
-export([photos_pick/2, media_list/1, photo_thumbnail/2]).
-on_load(init/0).

init() ->
    case erlang:load_nif("mob_photos_nif", 0) of
        ok -> ok;
        {error, _} -> ok
    end.

photos_pick(_Max, _Types) ->
    erlang:nif_error(nif_not_loaded).

%% Enumerate the media library. Async on both platforms: results land later
%% as {:media, :listed, items} (via {mob_file_result, <<"media">>,
%% <<"listed">>, Json}, decoded by core's Mob.Screen).
media_list(_OptsJson) ->
    erlang:nif_error(nif_not_loaded).

%% Downscaled JPEG + metadata for one image. Queues the work on a native
%% thread and returns ok at once (or a JSON error reply binary when it can't
%% be queued); the JSON reply arrives later at Receiver as
%% {mob_photos_thumbnail, Json}. MobPhotos.thumbnail/2 waits for it.
photo_thumbnail(_Receiver, _RequestJson) ->
    erlang:nif_error(nif_not_loaded).
