defmodule MobPhotos do
  @moduledoc """
  Photo / video library picker — a Mob plugin (extracted from mob core in
  Wave 2).

  On iOS 14+ no permission is required for the picker (it runs out of
  process — `PHPickerViewController`). On Android the system Photo Picker
  (`PickVisualMedia` / `PickMultipleVisualMedia`) likewise runs out of
  process; `READ_MEDIA_IMAGES` / `READ_MEDIA_VIDEO` (API 33+) or
  `READ_EXTERNAL_STORAGE` (API <= 32) are declared in this plugin's
  manifest and merged into the host AndroidManifest at build time. See the
  [permissions guide](https://hexdocs.pm/mob/permissions.html) for the cross-platform table.

  Results arrive as:

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
end
