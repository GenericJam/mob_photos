defmodule MobPhotos do
  @moduledoc """
  Photo / video library picker + library enumeration — a Mob plugin
  (extracted from mob core in Wave 2).

  Two access modes, with different permission postures:

    * `pick/2` — the **system picker**. On iOS 14+ no permission is required
      (it runs out of process — `PHPickerViewController`); on Android the
      system Photo Picker (`PickVisualMedia` / `PickMultipleVisualMedia`)
      likewise runs out of process. The user chooses individual items; the
      app never sees the rest of the library.

    * `list_media/2` — **library enumeration**. Lists the user's whole photo /
      video library with metadata (for an "AI Library Search" style screen).
      This reads the full MediaStore (Android `ContentResolver`), so it
      genuinely requires a runtime permission: `READ_MEDIA_IMAGES` /
      `READ_MEDIA_VIDEO` (Android 33+) or `READ_EXTERNAL_STORAGE` (API <= 32).
      Request it first with `Mob.Permissions.request(socket, :media)` (this
      plugin registers the `:media` capability with the platform permission
      registry) — the result arrives as `{:permission, :media, :granted | :denied}`.
      Those Android permissions are declared in this plugin's manifest and
      merged into the host AndroidManifest at build time; iOS needs
      `NSPhotoLibraryUsageDescription` in `Info.plist` (placeholder merged
      from the manifest — replace it). See the
      [permissions guide](https://hexdocs.pm/mob/permissions.html) for the cross-platform table.

  ## Picker results

      handle_info({:photos, :picked,    items},   socket)
      handle_info({:photos, :cancelled},           socket)

  Each item in `items` is:

      %{path: "/tmp/mob_pick_xxx.jpg", type: :image | :video,
        width: 1920, height: 1080}

  Platform parity notes (inherited from core, preserved by this plugin):
  iOS items carry only `path` + `type` (type as an atom); Android items
  carry all four keys but `type` is a string ("image"/"video") and
  `width`/`height` are `0` (the picker doesn't probe dimensions).

  iOS: `PHPickerViewController`. Android: `PickMultipleVisualMedia`.

  ## Enumeration results

      handle_info({:media, :listed, items}, socket)

  Each item in `items` is a map with **atom** keys. The native side builds a
  JSON array of metadata; the delivery rides core's generic
  `{:mob_file_result, "media", "listed", json}` path (the same decoder that
  serves `pick/2`), which decodes the JSON and atomizes each item's keys before
  your screen sees it:

      %{uri: "content://media/external/images/media/42",
        display_name: "IMG_0042.jpg",
        size: 2_481_233,
        date_added: 1_700_000_000,   # unix seconds
        mime_type: "image/jpeg",
        type: "image"}               # "image" | "video"

  On Android `uri` is a `content://` URI (open it via the host's
  `contentResolver`); the picker's `path` (a copied temp file) is a separate
  concept — enumeration does NOT copy bytes, it only lists metadata. iOS is
  not yet supported (`list_media/2` returns `{:error, :unsupported}` there).
  """

  @doc """
  Open the photo library picker.

  Options:
    - `max: integer` (default `1`) — maximum number of items selectable
    - `types: [:image | :video]` (default `[:image]`) — currently ignored by
      both native sides (core parity: both pickers show images + videos)
  """
  @spec pick(Mob.Socket.t(), keyword()) :: Mob.Socket.t()
  def pick(socket, opts \\ []) do
    max = Keyword.get(opts, :max, 1)
    types = Keyword.get(opts, :types, [:image]) |> Enum.map(&Atom.to_string/1)
    :mob_photos_nif.photos_pick(max, types)
    socket
  end

  @doc """
  Enumerate the user's media library (images and/or videos) with metadata.

  Asynchronous: the result is delivered to the **calling process** (call from
  a `Mob.Screen` callback such as `mount/3` or `handle_info/2`):

      handle_info({:media, :listed, items}, socket)

  where each item is a string-keyed map (see the "Enumeration results" section
  of the module doc). Requires the `:media` permission to be granted first
  (`Mob.Permissions.request(socket, :media)`) — without it Android returns an
  empty list, not an error.

  Options:
    - `type: :image | :video | :all` (default `:all`) — which media kinds to list
    - `limit: integer` (default `200`) — maximum items returned, newest first
      (ordered by `date_added` descending). `0` or a negative value means "no
      limit" — be cautious on large libraries (this is a synchronous query on
      the native side and the whole result is delivered as one message).

  Returns the socket immediately. On iOS this is currently unsupported and the
  NIF returns `{:error, :unsupported}` synchronously (no message is delivered);
  the socket is still returned unchanged.
  """
  @spec list_media(Mob.Socket.t(), keyword()) :: Mob.Socket.t()
  def list_media(socket, opts \\ []) do
    :mob_photos_nif.media_list(:json.encode(list_media_opts(opts)))
    socket
  end

  @doc """
  Build the option map passed to `media_list/1`. Pure function exposed so tests
  can pin defaults + serialisation without going through the NIF.
  """
  @spec list_media_opts(keyword()) :: map()
  def list_media_opts(opts) do
    %{
      "type" => Keyword.get(opts, :type, :all) |> normalize_type(),
      "limit" => Keyword.get(opts, :limit, 200)
    }
  end

  defp normalize_type(:image), do: "image"
  defp normalize_type(:video), do: "video"
  defp normalize_type(:all), do: "all"
  defp normalize_type(other) when is_binary(other), do: other
end
