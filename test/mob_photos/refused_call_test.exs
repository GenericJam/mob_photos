defmodule MobPhotos.RefusedCallTest do
  # Not async: the stub NIF goes into the :mob_photos app env, which is global.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  defmodule UnregisteredBridgeNif do
    def photos_pick(_max, _types), do: {:error, :bridge_not_registered}
    def media_list(_json), do: {:error, :bridge_not_registered}
  end

  defmodule AcceptingNif do
    def photos_pick(_max, _types), do: :ok
    def media_list(_json), do: :ok
  end

  @calls [
    {"pick/2", &MobPhotos.pick/1},
    {"list_media/2", &MobPhotos.list_media/1}
  ]

  setup do
    previous = Application.fetch_env(:mob_photos, :nif)

    on_exit(fn ->
      case previous do
        {:ok, nif} -> Application.put_env(:mob_photos, :nif, nif)
        :error -> Application.delete_env(:mob_photos, :nif)
      end
    end)

    %{socket: Mob.Socket.new(__MODULE__)}
  end

  test "a refused call is logged with the function and reason, and still returns the socket",
       %{socket: socket} do
    Application.put_env(:mob_photos, :nif, UnregisteredBridgeNif)

    for {name, fun} <- @calls do
      log = capture_log(fn -> assert fun.(socket) == socket end)
      assert log =~ "MobPhotos.#{name}"
      assert log =~ ":bridge_not_registered"
    end
  end

  test "an accepted call logs nothing", %{socket: socket} do
    Application.put_env(:mob_photos, :nif, AcceptingNif)

    for {_name, fun} <- @calls do
      assert capture_log(fn -> assert fun.(socket) == socket end) == ""
    end
  end
end
