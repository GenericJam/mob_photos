defmodule MobPhotos do
  @moduledoc """
  Photo / video library picker, library enumeration, image thumbnails and
  saving into the library — a Mob plugin (extracted from mob core in Wave 2).

  Four entry points, with different permission postures:

    * `pick/2` — the **system picker**. On iOS 14+ no permission is required
      (it runs out of process — `PHPickerViewController`); on Android the
      system Photo Picker (`PickVisualMedia` / `PickMultipleVisualMedia`)
      likewise runs out of process. The user chooses individual items; the
      app never sees the rest of the library.

    * `list_media/2` — **library enumeration**. Lists the user's whole photo /
      video library with metadata, newest first (Android `MediaStore`, iOS
      `PHAsset`). It genuinely requires a runtime permission: on Android
      `READ_MEDIA_IMAGES` / `READ_MEDIA_VIDEO` (33+) or `READ_EXTERNAL_STORAGE`
      (API <= 32), plus `ACCESS_MEDIA_LOCATION` (29+, no extra dialog) so
      `thumbnail/2` can read GPS; on iOS photo-library read access (limited
      access counts as granted). Request it first with
      `Mob.Permissions.request(socket, :media)` (this plugin registers the
      `:media` capability with the platform permission registry) — the result
      arrives as `{:permission, :media, :granted | :denied}`. The Android
      permissions are declared in this plugin's manifest and merged into the
      host AndroidManifest at build time; iOS needs
      `NSPhotoLibraryUsageDescription` in `Info.plist` (placeholder merged
      from the manifest — replace it). See the
      [permissions guide](https://hexdocs.pm/mob/permissions.html) for the
      cross-platform table.

    * `thumbnail/2` — **downscaled JPEG + metadata** for one image (a file
      path, an Android `content://` URI or an iOS `ph://` asset id).
      Synchronous. Files the app owns (e.g. a picker result's `path`) need no
      permission; library URIs / asset ids need `:media`.

    * `save/3` — **save a file into the library** (Android `MediaStore`,
      optionally in an album folder; iOS `PHPhotoLibrary`). Asks only to
      add, never to read: the `:media_save` capability (iOS add-only access,
      `NSPhotoLibraryAddUsageDescription`; Android 9 `WRITE_EXTERNAL_STORAGE`;
      nothing on Android 10+). Answers `{:photos, :saved, …}` or
      `{:photos, :save_failed, …}`.

  On the host (tests, `mix run`), `MobPhotos.Fake` stands in for the native
  side: `config :mob_photos, nif: MobPhotos.Fake`.

  ## Picker results

      handle_info({:photos, :picked,    items},   socket)
      handle_info({:photos, :cancelled},           socket)

  Item shapes differ per platform (inherited from core, preserved by this
  plugin):

      # iOS — type is an atom
      %{path: "/tmp/mob_pick_xxx.jpg", type: :image | :video,
        name: "IMG_0042", size: 2_481_233,
        width: 4032, height: 3024}        # width/height: images only

      # Android — type is a string
      %{path: "/data/.../cache/mob_pick_xxx.jpg", type: "image" | "video",
        name: "IMG_0042.jpg", size: 2_481_233,
        width: 4032, height: 3024}        # 0 when unknown (videos)

  Width/height are upright (EXIF orientation applied). The `path` is a copy
  in the app's cache/tmp dir; pass it to `thumbnail/2` for a model-sized
  JPEG plus EXIF metadata.

  ## Enumeration results

      handle_info({:media, :listed, items}, socket)

  Each item in `items` is a map with **atom** keys. The native side builds a
  JSON array of metadata; the delivery rides core's generic
  `{:mob_file_result, "media", "listed", json}` path (the same decoder that
  serves `pick/2`), which decodes the JSON and atomizes each item's keys before
  your screen sees it:

      %{uri: "content://media/external/images/media/42",  # iOS: "ph://<localIdentifier>"
        display_name: "IMG_0042.jpg",
        size: 2_481_233,
        date_added: 1_700_000_000,     # unix seconds
        date_taken: 1_699_999_000_123, # unix milliseconds
        width: 4032,
        height: 3024,
        mime_type: "image/jpeg",
        type: "image"}                 # "image" | "video"

  `size`, `date_taken`, `width` and `height` are **left out of the map** when
  the platform doesn't know them (core's JSON decoder would otherwise turn a
  JSON `null` into the atom `:null`), so read them with `item[:date_taken]`.
  On iOS `size` comes from the asset resource and `date_added` /
  `date_taken` are both the asset's `creationDate`; `display_name` and
  `mime_type` may be `""` if Photos has no resource record.

  On Android `uri` is a `content://` URI; on iOS it is `ph://` followed by the
  `PHAsset` local identifier. Both can be passed to `thumbnail/2`.
  Enumeration does NOT copy bytes, it only lists metadata.

  ## Thumbnails

      {:ok, %{path: thumb, width: 1280, height: 960, taken_at: "2024-05-01T12:34:56+02:00",
              latitude: 49.2827, longitude: -123.1207}} = MobPhotos.thumbnail(item.uri)

  See `thumbnail/2`.

  ## When the native side refuses a call

  `pick/2` and `list_media/2` keep returning the socket. When the native side
  refuses the call (on Android, `{:error, :bridge_not_registered}` when
  `MobPhotosBridge` never registered), they log a warning naming the function
  and the reason, and no `{:photos, …}` / `{:media, …}` message follows.
  `mix mob.selftest` reports an unregistered bridge before you get that far.
  """

  require Logger

  @default_max_size 1280
  @default_quality 80
  @default_timeout 30_000

  @typedoc "Metadata returned by `thumbnail/2`."
  @type thumbnail_info :: %{
          path: String.t(),
          width: pos_integer(),
          height: pos_integer(),
          orig_width: pos_integer(),
          orig_height: pos_integer(),
          mime: String.t() | nil,
          size: non_neg_integer() | nil,
          taken_at: String.t() | nil,
          latitude: float() | nil,
          longitude: float() | nil,
          altitude: float() | nil,
          make: String.t() | nil,
          model: String.t() | nil
        }

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
    warn_on_error(nif().photos_pick(max, types), "pick/2")
    socket
  end

  @doc """
  Enumerate the user's media library (images and/or videos) with metadata.

  Asynchronous: the result is delivered to the **calling process** (call from
  a `Mob.Screen` callback such as `mount/3` or `handle_info/2`):

      handle_info({:media, :listed, items}, socket)

  where each item is an atom-keyed map (see the "Enumeration results" section
  of the module doc). Requires the `:media` permission to be granted first
  (`Mob.Permissions.request(socket, :media)`) — without it an empty list is
  delivered, not an error.

  Options:
    - `type: :image | :video | :all` (default `:all`) — which media kinds to list
    - `limit: integer` (default `200`) — maximum items returned, newest first
      (Android: `date_added` descending; iOS: `creationDate` descending). `0`
      or a negative value means "no limit" — be cautious on large libraries
      (the whole result is delivered as one message).

  Returns the socket immediately; the native query runs off the BEAM
  schedulers.
  """
  @spec list_media(Mob.Socket.t(), keyword()) :: Mob.Socket.t()
  def list_media(socket, opts \\ []) do
    warn_on_error(nif().media_list(:json.encode(list_media_opts(opts))), "list_media/2")
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

  @doc """
  Write a downscaled, upright JPEG of an image and return it with the image's
  metadata. **Synchronous**: the caller waits (typically tens to a few hundred
  ms; longer if iOS must download an iCloud original). The decode itself runs
  on a native thread (a two-wide operation queue on iOS, a two-thread pool on
  Android), never on a BEAM scheduler, so a slow image doesn't hold up other
  processes or the VM's file I/O; only the calling process waits.

  `source` is one of:

    * an absolute file path (or a `file://` URL), e.g. a `pick/2` item's `path`
    * an Android `content://` URI, e.g. a `list_media/2` item's `uri`
    * an iOS asset id `"ph://<localIdentifier>"`, e.g. a `list_media/2` item's `uri`

  The JPEG goes to the app's cache dir with EXIF orientation applied to the
  pixels (no orientation tag needed to display it). Its name is derived from
  the source and options, so asking again for the same thumbnail overwrites
  the previous file instead of piling up copies; the OS may purge the cache
  dir, so use the file promptly or copy it.

  Options:
    - `max_size:` longest side of the thumbnail in pixels, `1..16384`
      (default `1280`). Images already smaller are not upscaled.
    - `quality:` JPEG quality `1..100` (default `80`), handed to the platform
      encoder (Android `Bitmap.compress`, iOS ImageIO as `quality / 100`), so
      the same value gives somewhat different file sizes per platform
    - `timeout:` milliseconds to wait, `1..4_294_967_295` (default `30_000`).
      The caller gets `{:error, :timeout}` at that point and never sees a late
      reply. A request still queued natively at its deadline is skipped; iOS
      also cancels a running iCloud download. On Android a decode that has
      already started finishes in the background and its result is dropped.

  On success returns `{:ok, info}` (see `t:thumbnail_info/0`):

    * `path`, `width`, `height` — the thumbnail
    * `orig_width`, `orig_height` — the source image, upright
    * `mime` — the source's MIME type; `size` — the source's byte size
    * `taken_at` — ISO-8601 capture time: EXIF `DateTimeOriginal` with its
      `OffsetTimeOriginal` when both are present, else the platform's capture
      date (iOS `PHAsset.creationDate`, Android `MediaStore.DATE_TAKEN`) in
      UTC, else the bare EXIF local time without an offset
    * `latitude`, `longitude`, `altitude` (metres) — EXIF GPS, or the
      `PHAsset` location for `ph://` ids. Android only hands GPS to apps
      holding `ACCESS_MEDIA_LOCATION` (granted with `:media`), and its photo
      picker zeroes GPS in the copies it hands out. A `(0, 0)` fix is treated
      as absent.
    * `make`, `model` — camera EXIF

  Any metadata the image doesn't carry is `nil`.

  Errors: `{:error, :not_found}`, `{:error, :unsupported}` (not a decodable
  image — videos included), `{:error, :permission}` (library access not
  granted, or a file the app may not read), `{:error, :timeout}`, or
  `{:error, message}` with a string for anything else (including a source
  this platform can't open, like a `ph://` id on Android).

  Raises `ArgumentError` for an unknown option or an out-of-range value.
  """
  @spec thumbnail(String.t(), keyword()) ::
          {:ok, thumbnail_info()}
          | {:error, :not_found | :unsupported | :permission | :timeout | String.t()}
  def thumbnail(source, opts \\ []) when is_binary(source) do
    with {:ok, json} <- thumbnail_reply(nif(), source, opts) do
      decode_thumbnail_result(json)
    end
  end

  @doc false
  # The native JSON reply to a thumbnail request, through a given NIF module,
  # before decode_thumbnail_result/1: MobPhotos.SelfTest runs the real
  # request/reply path and reads reply fields thumbnail/2 drops (the iOS
  # "authorization" status); its unit tests pass a stub module.
  @spec thumbnail_reply(module(), String.t(), keyword()) ::
          {:ok, binary()} | {:error, :timeout | String.t()}
  def thumbnail_reply(nif, source, opts) when is_atom(nif) and is_binary(source) do
    with {:ok, request} <- thumbnail_request(source, opts) do
      request
      |> :json.encode()
      |> IO.iodata_to_binary()
      |> await_thumbnail(request["timeout_ms"], nif)
    end
  end

  # The NIF only queues the work and returns :ok (or a JSON error reply when it
  # can't even queue it); the reply arrives as {:mob_photos_thumbnail, json}.
  # It is addressed to a throwaway receiver, not the caller, so a reply that
  # lands after the timeout dies with the receiver instead of turning up in
  # the caller's mailbox (a Mob.Screen would hand it to handle_info).
  defp await_thumbnail(request_json, timeout, nif) do
    caller = self()
    tag = make_ref()

    # The caller gives up at `timeout` on every platform. iOS also cancels
    # its pending request natively at the same deadline; whichever lands
    # first, the caller sees {:error, :timeout}.
    {receiver, mref} =
      spawn_monitor(fn ->
        receive do
          {:mob_photos_thumbnail, json} -> send(caller, {tag, json})
        after
          timeout -> :ok
        end
      end)

    case call_thumbnail_nif(nif, receiver, mref, request_json) do
      :ok ->
        receive do
          {^tag, json} ->
            Process.demonitor(mref, [:flush])
            {:ok, json}

          {:DOWN, ^mref, :process, _pid, _reason} ->
            {:error, :timeout}
        end

      json when is_binary(json) ->
        Process.exit(receiver, :kill)
        Process.demonitor(mref, [:flush])
        {:ok, json}

      other ->
        Process.exit(receiver, :kill)
        Process.demonitor(mref, [:flush])
        {:error, "photo_thumbnail/2 returned #{inspect(other)}, expected :ok or a JSON reply"}
    end
  end

  # A NIF that raises (not loaded, badarg) must not leave the monitored
  # receiver behind to deliver a stray :DOWN into the caller's mailbox.
  defp call_thumbnail_nif(nif, receiver, mref, request_json) do
    nif.photo_thumbnail(receiver, request_json)
  rescue
    e ->
      Process.exit(receiver, :kill)
      Process.demonitor(mref, [:flush])
      reraise e, __STACKTRACE__
  end

  # ── Save ─────────────────────────────────────────────────────────────────

  # Extension → {type, MIME}. The platform's own "image/*" would be refused
  # by MediaStore, and iOS needs to know a video from a picture.
  @save_types %{
    ".jpg" => {"image", "image/jpeg"},
    ".jpeg" => {"image", "image/jpeg"},
    ".png" => {"image", "image/png"},
    ".gif" => {"image", "image/gif"},
    ".webp" => {"image", "image/webp"},
    ".heic" => {"image", "image/heic"},
    ".heif" => {"image", "image/heif"},
    ".mp4" => {"video", "video/mp4"},
    ".m4v" => {"video", "video/x-m4v"},
    ".mov" => {"video", "video/quicktime"}
  }

  @typedoc "Why `save/3` failed (`{:photos, :save_failed, %{reason: reason}}`)."
  @type save_error :: :permission_denied | :not_found | :unsupported | String.t()

  @doc """
  Save a picture or video file into the phone's photo library, where the
  Photos / Gallery app shows it.

  Asynchronous: the result is delivered to the **calling process** (call it
  from a `Mob.Screen` callback):

      handle_info({:photos, :saved, %{path: path, uri: uri}}, socket)
      handle_info({:photos, :save_failed, %{path: path, reason: reason}}, socket)

  `uri` is the new item: a `content://` URI on Android, `"ph://<localIdentifier>"`
  on iOS. `reason` is `:permission_denied` (the user refused the photo
  library, see below), `:not_found` (no such file), `:unsupported` (not a
  `.jpg`/`.jpeg`/`.png`/`.gif`/`.webp`/`.heic`/`.heif` picture or a
  `.mp4`/`.m4v`/`.mov` video), or a message from the platform.

  The file is copied; the original stays where it is.

  Options:
    - `album:` a folder name, e.g. `"Bezalel"` (default: none). Android puts
      the item in `Pictures/<album>` (videos: `Movies/<album>`), which the
      Gallery shows as an album. iOS ignores it: adding to an album needs
      full library access, and saving only asks to add.
    - `name:` the item's file name (default: the file's own). Android renames
      a clash (`"name (1).png"`); iOS keeps it as the original file name.

  ## Permission

  Saving never needs read access to the library.

    * **iOS**: add-only access (`PHAccessLevelAddOnly`). The first save asks;
      the host's `Info.plist` must carry `NSPhotoLibraryAddUsageDescription`
      (this plugin merges a placeholder; replace it). If the user refused,
      every save fails with `:permission_denied` until they allow it in
      Settings.
    * **Android 10+** (API 29): none. The app adds its own MediaStore items.
    * **Android 9** (API 28): `WRITE_EXTERNAL_STORAGE`, declared by this
      plugin. Without the grant a save fails with `:permission_denied`.

  To ask up front (and to get the prompt on Android 9), request the
  `:media_save` capability first:
  `Mob.Permissions.request(socket, :media_save)`, answered with
  `{:permission, :media_save, :granted | :denied}`; Android 10+ grants it at
  once without a dialog.

  Raises `ArgumentError` for an unknown option, or an `album:` / `name:`
  that isn't a plain non-empty name (no `/`, not `.` or `..`).
  """
  @spec save(Mob.Socket.t(), String.t(), keyword()) :: Mob.Socket.t()
  def save(socket, path, opts \\ []) when is_binary(path) do
    case save_request(path, opts) do
      {:ok, request} -> start_save(self(), path, request)
      {:error, reason} -> send(self(), {:photos, :save_failed, %{path: path, reason: reason}})
    end

    socket
  end

  @doc false
  # The JSON request handed to the photo_save NIF, or the reason it can't be
  # made. Public (but undocumented) so it's testable without the NIF.
  @spec save_request(String.t(), keyword()) :: {:ok, map()} | {:error, :not_found | :unsupported}
  def save_request(path, opts) when is_binary(path) do
    opts = Keyword.validate!(opts, album: nil, name: nil)
    album = plain_name!(opts[:album], :album)
    name = plain_name!(opts[:name], :name)

    with {:ok, {type, mime}} <- save_type(path),
         true <- File.regular?(path) || {:error, :not_found} do
      {:ok,
       %{
         "path" => Path.expand(path),
         "name" => name || Path.basename(path),
         "type" => type,
         "mime" => mime,
         "album" => album || ""
       }}
    end
  end

  defp save_type(path) do
    case Map.fetch(@save_types, path |> Path.extname() |> String.downcase()) do
      {:ok, type} -> {:ok, type}
      :error -> {:error, :unsupported}
    end
  end

  defp plain_name!(nil, _opt), do: nil

  defp plain_name!(value, opt) do
    if is_binary(value) and String.valid?(value) and String.trim(value) != "" and
         value not in [".", ".."] and not String.contains?(value, ["/", "\\", <<0>>]) do
      value
    else
      raise ArgumentError,
            "#{opt} must be a non-empty name without \"/\", got: #{inspect(value)}"
    end
  end

  # The native side answers a receiver, not the caller: the receiver turns
  # the raw JSON reply into the public message, and goes away with the caller
  # if the caller dies first (the user may sit on the iOS prompt).
  defp start_save(caller, path, request) do
    receiver =
      spawn(fn ->
        mref = Process.monitor(caller)

        receive do
          {:mob_photos_saved, json} -> send(caller, decode_save_result(path, json))
          {:DOWN, ^mref, :process, _pid, _reason} -> :ok
        end
      end)

    json = request |> :json.encode() |> IO.iodata_to_binary()

    case call_save_nif(receiver, json) do
      :ok ->
        :ok

      reply when is_binary(reply) ->
        send(receiver, {:mob_photos_saved, reply})

      other ->
        Process.exit(receiver, :kill)

        send(
          caller,
          {:photos, :save_failed,
           %{
             path: path,
             reason: "photo_save/2 returned #{inspect(other)}, expected :ok or a JSON reply"
           }}
        )
    end
  end

  defp call_save_nif(receiver, json) do
    nif().photo_save(receiver, json)
  rescue
    e ->
      Process.exit(receiver, :kill)
      reraise e, __STACKTRACE__
  end

  @doc false
  # The native JSON reply → the message the caller receives. Public (but
  # undocumented) so the decoding is testable without the NIF.
  @spec decode_save_result(String.t(), binary()) ::
          {:photos, :saved, %{path: String.t(), uri: String.t()}}
          | {:photos, :save_failed, %{path: String.t(), reason: save_error()}}
  def decode_save_result(path, json) when is_binary(json) do
    case :json.decode(json) do
      %{"uri" => uri} when is_binary(uri) ->
        {:photos, :saved, %{path: path, uri: uri}}

      %{"error" => reason} when is_binary(reason) ->
        {:photos, :save_failed, %{path: path, reason: decode_save_error(reason)}}
    end
  end

  defp decode_save_error("permission_denied"), do: :permission_denied
  defp decode_save_error("not_found"), do: :not_found
  defp decode_save_error(message), do: message

  @max_max_size 16_384
  # The largest `after` timeout the VM accepts.
  @max_timeout 4_294_967_295

  @doc false
  # The JSON request handed to the photo_thumbnail NIF. Public (but
  # undocumented) so the option normalisation and source classification are
  # testable without the NIF.
  @spec thumbnail_request(String.t(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def thumbnail_request(source, opts) when is_binary(source) do
    opts =
      Keyword.validate!(opts,
        max_size: @default_max_size,
        quality: @default_quality,
        timeout: @default_timeout
      )

    max_size = Keyword.fetch!(opts, :max_size)
    quality = Keyword.fetch!(opts, :quality)
    timeout = Keyword.fetch!(opts, :timeout)

    unless is_integer(max_size) and max_size in 1..@max_max_size do
      raise ArgumentError,
            "max_size must be an integer in 1..#{@max_max_size}, got: #{inspect(max_size)}"
    end

    unless is_integer(quality) and quality in 1..100 do
      raise ArgumentError, "quality must be an integer in 1..100, got: #{inspect(quality)}"
    end

    unless is_integer(timeout) and timeout in 1..@max_timeout do
      raise ArgumentError,
            "timeout must be an integer in 1..#{@max_timeout} (ms), got: #{inspect(timeout)}"
    end

    with {:ok, kind, target} <- classify_source(source) do
      {:ok,
       %{
         "kind" => kind,
         "source" => target,
         "max_size" => max_size,
         "quality" => quality,
         "timeout_ms" => timeout
       }}
    end
  end

  defp classify_source(source) do
    if String.valid?(source) do
      classify_valid_source(source)
    else
      {:error, "invalid source: not valid UTF-8"}
    end
  end

  defp classify_valid_source("content://" <> rest = uri) when rest != "",
    do: {:ok, "content", uri}

  defp classify_valid_source("ph://" <> id) when id != "", do: {:ok, "asset", id}
  # file:///p, file://localhost/p and file:/p. Not URI.parse: it would cut an
  # unencoded "#" or "?" (legal in file names) off as fragment/query.
  defp classify_valid_source("file:///" <> rest = url), do: file_url("/" <> rest, url)
  defp classify_valid_source("file://localhost/" <> rest = url), do: file_url("/" <> rest, url)

  defp classify_valid_source("file://" <> _ = url),
    do: {:error, "invalid source #{inspect(url)}: not a local file:// URL"}

  defp classify_valid_source("file:/" <> rest = url), do: file_url("/" <> rest, url)
  defp classify_valid_source("/" <> _ = path), do: {:ok, "file", path}

  defp classify_valid_source(other) do
    {:error,
     "invalid source #{inspect(other)}: expected an absolute file path, a content:// URI or a ph:// asset id"}
  end

  defp file_url(encoded_path, url) do
    path = URI.decode(encoded_path)

    if String.valid?(path),
      do: {:ok, "file", path},
      else: {:error, "invalid source #{inspect(url)}: path is not valid UTF-8"}
  rescue
    ArgumentError -> {:error, "invalid source #{inspect(url)}: malformed percent-encoding"}
  end

  @doc false
  # Decodes the NIF's JSON reply into the public result. Public (but
  # undocumented) so the decoding is testable without the NIF.
  @spec decode_thumbnail_result(binary()) ::
          {:ok, thumbnail_info()} | {:error, atom() | String.t()}
  def decode_thumbnail_result(json) when is_binary(json) do
    case :json.decode(json) do
      %{"error" => reason} -> {:error, decode_error(reason)}
      %{"path" => path} = reply when is_binary(path) -> {:ok, build_info(reply)}
    end
  end

  defp decode_error("not_found"), do: :not_found
  defp decode_error("unsupported"), do: :unsupported
  defp decode_error("permission"), do: :permission
  defp decode_error("timeout"), do: :timeout
  defp decode_error(message) when is_binary(message), do: message

  defp build_info(reply) do
    {latitude, longitude, altitude} =
      location(field(reply, "latitude"), field(reply, "longitude"), field(reply, "altitude"))

    %{
      path: reply["path"],
      width: field(reply, "width"),
      height: field(reply, "height"),
      orig_width: field(reply, "orig_width"),
      orig_height: field(reply, "orig_height"),
      mime: text(field(reply, "mime")),
      size: field(reply, "size"),
      taken_at:
        taken_at(
          field(reply, "exif_datetime"),
          field(reply, "exif_offset"),
          field(reply, "date_taken_ms")
        ),
      latitude: latitude,
      longitude: longitude,
      altitude: altitude,
      make: text(field(reply, "make")),
      model: text(field(reply, "model"))
    }
  end

  defp field(reply, key) do
    case Map.get(reply, key) do
      :null -> nil
      value -> value
    end
  end

  # A redacted fix (Android's photo picker zeroes the GPS tags) or a
  # placeholder reads as (0, 0); its altitude means nothing either.
  defp location(lat, lon, alt) when is_number(lat) and is_number(lon) and (lat != 0 or lon != 0),
    do: {lat / 1, lon / 1, if(is_number(alt), do: alt / 1)}

  defp location(_lat, _lon, _alt), do: {nil, nil, nil}

  defp text(value) when is_binary(value) do
    case value |> String.replace("\0", "") |> String.trim() do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp text(_value), do: nil

  # Precedence: EXIF local time + its offset (exact and zoned) > the
  # platform's absolute capture date (UTC) > bare EXIF local time.
  defp taken_at(exif_datetime, exif_offset, date_taken_ms) do
    naive = parse_exif_datetime(exif_datetime)
    offset = parse_exif_offset(exif_offset)

    cond do
      naive && offset -> NaiveDateTime.to_iso8601(naive) <> offset
      platform = unix_ms_to_iso8601(date_taken_ms) -> platform
      naive -> NaiveDateTime.to_iso8601(naive)
      true -> nil
    end
  end

  # EXIF DateTimeOriginal: "YYYY:MM:DD HH:MM:SS"; cameras without a clock
  # write blanks or zeros, which fail NaiveDateTime.new/6.
  defp parse_exif_datetime(
         <<y::binary-4, ":", mo::binary-2, ":", d::binary-2, " ", h::binary-2, ":", mi::binary-2,
           ":", s::binary-2, _rest::binary>>
       ) do
    with [y, mo, d, h, mi, s] <- parse_ints([y, mo, d, h, mi, s]),
         {:ok, naive} <- NaiveDateTime.new(y, mo, d, h, mi, s) do
      naive
    else
      _ -> nil
    end
  end

  defp parse_exif_datetime(_value), do: nil

  defp parse_ints(parts) do
    Enum.reduce_while(parts, [], fn part, acc ->
      case Integer.parse(part) do
        {n, ""} -> {:cont, [n | acc]}
        _ -> {:halt, :error}
      end
    end)
    |> case do
      :error -> :error
      ints -> Enum.reverse(ints)
    end
  end

  # EXIF OffsetTimeOriginal: "+HH:MM" / "-HH:MM", within the real range of
  # UTC offsets (-12:00..+14:00).
  defp parse_exif_offset(<<sign, _, _, ":", _, _>> = offset) when sign in [?+, ?-] do
    with [h, m] <- parse_ints([binary_part(offset, 1, 2), binary_part(offset, 4, 2)]),
         true <- h <= 14 and m <= 59 do
      offset
    else
      _ -> nil
    end
  end

  defp parse_exif_offset(_value), do: nil

  # A non-positive or absurd value (a row written in the wrong unit) is
  # "unknown", not a crash.
  defp unix_ms_to_iso8601(ms) when is_integer(ms) and ms > 0 do
    case DateTime.from_unix(div(ms, 1000)) do
      {:ok, datetime} -> DateTime.to_iso8601(datetime)
      {:error, _} -> nil
    end
  end

  defp unix_ms_to_iso8601(_ms), do: nil

  # The NIF module. Tests put a stub in the :mob_photos app env.
  defp nif, do: Application.get_env(:mob_photos, :nif, :mob_photos_nif)

  defp warn_on_error({:error, reason}, function) do
    Logger.warning("MobPhotos.#{function}: the native side refused the call: #{inspect(reason)}")
  end

  defp warn_on_error(_answer, _function), do: :ok
end
