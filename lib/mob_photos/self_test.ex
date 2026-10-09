defmodule MobPhotos.SelfTest do
  @moduledoc """
  The plugin's on-device proof (`Mob.Plugin.SelfTest`), run by
  `mix mob.selftest` and mob_ci for every activated plugin.

  The picker (`photos_pick/2`) opens UI and `media_list/1` reads the library,
  so neither is a probe. `photo_thumbnail/2` is: asked for an image that does
  not exist, the native side looks for it, finds nothing and answers through
  the same worker + delivery path a real thumbnail takes. Nothing is decoded,
  nothing is written, no dialog is shown. Two requests, each bounded at 5 s:

    1. **A file the app could own, which is missing**
       (`/mob_photos-selftest-no-such-image.jpg`) must answer
       `{:error, :not_found}`. iOS: the NIF queued the request on its
       operation queue, `NSFileManager` found no file and the reply came back
       as `{:mob_photos_thumbnail, json}`. Android: the zig NIF found the
       `MobPhotosBridge` class and method IDs (`nativeRegister` ran; otherwise
       it answers "mob_photos bridge not registered"), the bridge has a
       Context (otherwise "no context yet"), its worker pool opened the path
       (`ENOENT`) and `nativeDeliverThumbnail` delivered the reply. No
       permission is involved on either platform, so this is the same answer
       on a simulator, an emulator and a phone. It proves the NIF is linked
       and initialised.
    2. **A library item that does not exist** must answer
       `{:error, :not_found}`. iOS (`ph://mob_photos-selftest-no-such-asset`):
       `PHPhotoLibrary authorizationStatusForAccessLevel:` (a status read,
       never a prompt) is authorized or limited and `PHAsset` found no such
       local identifier. When the library is not authorized the answer is
       `{:error, :permission}`: on a physical device that is
       `{:skip, :needs_user}` (someone has to grant `:media`); on a simulator
       the runner pre-grants the manifest's `:media` capability
       (`xcrun simctl privacy grant photos`), so it is a failure. Android
       (`content://media/external/images/media/9223372036854775807`):
       `MediaProvider` looks the row up under its own identity before it
       checks the caller and throws `FileNotFoundException("No item at …")`,
       so the answer is `:not_found` with or without `READ_MEDIA_*`; this leg
       proves the bridge reaches `ContentResolver` → `MediaProvider`, not the
       grant. A `:permission` answer is still classified as on iOS (skip on a
       phone, failure on an emulator, where `pm grant` pre-granted it).

  Expected: `:pass` on an iOS simulator with photos granted, an Android
  emulator and an Android phone; `:pass` or `{:skip, :needs_user}` on an
  iPhone, depending on whether the user granted `:media`. The host stub's
  `nif_not_loaded` is a failure; so is any other answer, or no answer.
  """
  @behaviour Mob.Plugin.SelfTest

  @timeout 5_000
  @missing_file "/mob_photos-selftest-no-such-image.jpg"
  @missing_asset %{
    ios: "ph://mob_photos-selftest-no-such-asset",
    android: "content://media/external/images/media/9223372036854775807"
  }

  @impl true
  def run(ctx), do: run(ctx, :mob_photos_nif)

  @doc false
  # `nif` is the NIF module; unit tests pass a stub.
  @spec run(Mob.Plugin.SelfTest.ctx(), module()) :: Mob.Plugin.SelfTest.result()
  def run(%{platform: platform, device: device}, nif) do
    with :ok <- own_file(nif, platform) do
      library(nif, platform, device)
    end
  rescue
    e in [ErlangError, UndefinedFunctionError] ->
      {:fail,
       "mob_photos_nif is not linked into this build: photo_thumbnail/2 raised #{Exception.message(e)}"}
  end

  defp own_file(nif, platform) do
    case MobPhotos.thumbnail_via(nif, @missing_file, timeout: @timeout) do
      {:error, :not_found} ->
        :ok

      {:error, "mob_photos bridge not registered"} ->
        {:fail,
         "photo_thumbnail/2 answered \"mob_photos bridge not registered\": the Kotlin " <>
           "MobPhotosBridge.register() never ran (nativeRegister) or a method-ID lookup failed"}

      other ->
        {:fail,
         "photo_thumbnail/2 of the missing file #{@missing_file} on #{platform} answered " <>
           "#{describe(other)}, expected {:error, :not_found}"}
    end
  end

  defp library(nif, platform, device) do
    source = Map.fetch!(@missing_asset, platform)

    case MobPhotos.thumbnail_via(nif, source, timeout: @timeout) do
      {:error, :not_found} ->
        :pass

      {:error, :permission} when device == :physical ->
        {:skip, :needs_user}

      {:error, :permission} ->
        {:fail,
         "photo_thumbnail/2 of the missing library item #{source} on an #{platform} #{device} " <>
           "answered {:error, :permission}: #{library_denied(platform)}, though the runner " <>
           "pre-grants the manifest's :media permissions on #{device}s; expected {:error, :not_found}"}

      other ->
        {:fail,
         "photo_thumbnail/2 of the missing library item #{source} on #{platform} answered " <>
           "#{describe(other)}, expected {:error, :not_found}"}
    end
  end

  defp library_denied(:ios), do: "PHPhotoLibrary is not authorized (simctl privacy grant photos)"
  defp library_denied(:android), do: "MediaStore refused the read (pm grant READ_MEDIA_IMAGES)"

  defp describe({:error, :timeout}),
    do:
      "{:error, :timeout} (no {:mob_photos_thumbnail, json} reply within #{div(@timeout, 1000)} s)"

  defp describe(other), do: inspect(other)
end
