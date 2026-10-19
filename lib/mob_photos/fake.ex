defmodule MobPhotos.Fake do
  @moduledoc """
  A stand-in for mob_photos' native side on the host (tests, `mix run`, a
  dev node without the NIF). Point `MobPhotos` at it:

      # config/test.exs
      config :mob_photos, nif: MobPhotos.Fake

  It answers the way the phone does, through the same messages:

    * `MobPhotos.save/3` copies the file into `library_dir/0` (under
      `<album>/` when given, renaming a clash to `"name (1).png"` like
      Android) and answers `{:photos, :saved, %{path, uri}}` with a
      `"fake://<copy>"` uri. `set_save_answer/1` makes saves fail instead.
    * `MobPhotos.pick/2` answers `{:photos, :cancelled}`.
    * `MobPhotos.list_media/2` answers `{:media, :listed, []}`.
    * `MobPhotos.thumbnail/2` answers `{:error, :unsupported}`.

  State lives in the `:mob_photos` application env, so a test that changes it
  must not be `async` (and should `reset/0` in its setup).
  """

  @doc "Where saved files land: `config :mob_photos, :fake_library_dir`, else a dir in the system tmp dir."
  @spec library_dir() :: Path.t()
  def library_dir do
    Application.get_env(:mob_photos, :fake_library_dir) ||
      Path.join(System.tmp_dir!(), "mob_photos_fake_library")
  end

  @doc "The files saved so far, relative to `library_dir/0`, sorted."
  @spec saved() :: [Path.t()]
  def saved do
    dir = library_dir()

    dir
    |> Path.join("**")
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(&Path.relative_to(&1, dir))
    |> Enum.sort()
  end

  @doc """
  How the next saves answer: `:ok` (the default), `:permission_denied`
  (as when the user refused the library), or `{:error, message}`.
  """
  @spec set_save_answer(:ok | :permission_denied | {:error, String.t()}) :: :ok
  def set_save_answer(answer) when answer in [:ok, :permission_denied], do: put_answer(answer)
  def set_save_answer({:error, message} = answer) when is_binary(message), do: put_answer(answer)

  defp put_answer(answer), do: Application.put_env(:mob_photos, :fake_save_answer, answer)

  @doc "Empties `library_dir/0` and saves answer `:ok` again."
  @spec reset() :: :ok
  def reset do
    File.rm_rf!(library_dir())
    Application.delete_env(:mob_photos, :fake_save_answer)
  end

  # ── The NIF's functions ─────────────────────────────────────────────────

  @doc false
  @spec photos_pick(integer(), [String.t()]) :: :ok
  def photos_pick(_max, _types) do
    send(self(), {:photos, :cancelled})
    :ok
  end

  @doc false
  @spec media_list(binary()) :: :ok
  def media_list(_opts_json) do
    send(self(), {:media, :listed, []})
    :ok
  end

  @doc false
  @spec photo_thumbnail(pid(), binary()) :: binary()
  def photo_thumbnail(_receiver, _request_json), do: ~s({"error":"unsupported"})

  @doc false
  @spec photo_save(pid(), binary()) :: :ok
  def photo_save(receiver, request_json) do
    request = :json.decode(request_json)

    reply =
      case Application.get_env(:mob_photos, :fake_save_answer, :ok) do
        :ok -> copy(request)
        :permission_denied -> %{"error" => "permission_denied"}
        {:error, message} -> %{"error" => message}
      end

    send(receiver, {:mob_photos_saved, IO.iodata_to_binary(:json.encode(reply))})
    :ok
  end

  defp copy(%{"path" => path, "name" => name, "album" => album}) do
    dir = Path.join(library_dir(), album)
    File.mkdir_p!(dir)
    dest = free_name(dir, name)

    case File.cp(path, dest) do
      :ok -> %{"uri" => "fake://" <> dest}
      {:error, :enoent} -> %{"error" => "not_found"}
      {:error, reason} -> %{"error" => inspect(reason)}
    end
  end

  defp free_name(dir, name) do
    ext = Path.extname(name)
    stem = Path.basename(name, ext)

    Stream.iterate(0, &(&1 + 1))
    |> Stream.map(fn
      0 -> Path.join(dir, name)
      n -> Path.join(dir, "#{stem} (#{n})#{ext}")
    end)
    |> Enum.find(&(not File.exists?(&1)))
  end
end
