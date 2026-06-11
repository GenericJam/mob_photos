%% mob_photos_nif — Erlang NIF module for the photo/video picker tier-1 plugin.
%%
%% iOS: priv/native/ios/mob_photos_nif.m (Objective-C: PHPickerViewController,
%% iOS 14+, runs out of process so no runtime permission is needed). Android:
%% priv/native/jni/mob_photos_nif.zig bridging to the system Photo Picker
%% (PickVisualMedia / PickMultipleVisualMedia) via the io.mob.photos
%% MobPhotosBridge Kotlin bridge. Both register this module via ERL_NIF_INIT
%% and are statically linked into the host binary on device. On a host dev
%% build neither is linked, so on_load tolerates the failure and the NIF
%% falls back to nif_error until the native merge links one.
-module(mob_photos_nif).
-export([photos_pick/2]).
-on_load(init/0).

init() ->
    case erlang:load_nif("mob_photos_nif", 0) of
        ok -> ok;
        {error, _} -> ok
    end.

photos_pick(_Max, _Types) ->
    erlang:nif_error(nif_not_loaded).
