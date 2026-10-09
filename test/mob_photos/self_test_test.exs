defmodule MobPhotos.SelfTestTest do
  use ExUnit.Case, async: true

  alias MobDev.Plugin.{Manifest, Validator}
  alias MobPhotos.SelfTest

  @plugin_dir Path.expand("../..", __DIR__)

  @not_found ~s({"error":"not_found"})
  @permission ~s({"error":"permission"})

  # Stand-ins for :mob_photos_nif. Each answers photo_thumbnail/2 the way the
  # native worker does: :ok now, {:mob_photos_thumbnail, json} to the receiver
  # later, chosen by the request's source kind ("file", "asset" on iOS,
  # "content" on Android).
  defmodule Reply do
    def send_for(receiver, request, answers) do
      %{"kind" => kind} = :json.decode(request)
      send(receiver, {:mob_photos_thumbnail, Map.fetch!(answers, kind)})
      :ok
    end
  end

  defmodule PassNif do
    def photo_thumbnail(receiver, request) do
      Reply.send_for(receiver, request, %{
        "file" => ~s({"error":"not_found"}),
        "asset" => ~s({"error":"not_found"}),
        "content" => ~s({"error":"not_found"})
      })
    end
  end

  defmodule LibraryDeniedNif do
    def photo_thumbnail(receiver, request) do
      Reply.send_for(receiver, request, %{
        "file" => ~s({"error":"not_found"}),
        "asset" => ~s({"error":"permission","authorization":"denied"}),
        "content" => ~s({"error":"permission"})
      })
    end
  end

  defmodule NotLoadedNif do
    def photo_thumbnail(_receiver, _request), do: :erlang.nif_error(:nif_not_loaded)
  end

  # Android's zig NIF when MobPhotosBridge.nativeRegister never ran.
  defmodule UnregisteredNif do
    def photo_thumbnail(_receiver, _request),
      do: ~s({"error":"mob_photos bridge not registered"})
  end

  defmodule ErrorAtomNif do
    def photo_thumbnail(_receiver, _request), do: :error
  end

  defmodule FileAnswerNif do
    def photo_thumbnail(receiver, request) do
      %{"kind" => "file"} = :json.decode(request)
      send(receiver, {:mob_photos_thumbnail, Process.get(:file_answer)})
      :ok
    end
  end

  defmodule LibraryAnswerNif do
    def photo_thumbnail(receiver, request) do
      answer =
        case :json.decode(request) do
          %{"kind" => "file"} -> ~s({"error":"not_found"})
          %{"kind" => _library} -> Process.get(:library_answer)
        end

      send(receiver, {:mob_photos_thumbnail, answer})
      :ok
    end
  end

  # The stubs run in the caller's process (the NIF call is synchronous), so
  # Process.put/2 in the test reaches them.
  defp run_with(nif, ctx, key, answer) do
    Process.put(key, answer)
    result = SelfTest.run(ctx, nif)
    assert Mob.Plugin.SelfTest.result?(result)
    result
  end

  defp run!(ctx, nif) do
    result = SelfTest.run(ctx, nif)
    assert Mob.Plugin.SelfTest.result?(result)
    result
  end

  test "the manifest declares it and the validator raises no selftest warning" do
    {:ok, m} = Manifest.load(@plugin_dir)
    assert m.selftest == MobPhotos.SelfTest
    assert %{errors: [], warnings: warnings} = Validator.validate_plugin(m, @plugin_dir)
    refute Enum.any?(warnings, &(&1 =~ "selftest"))
  end

  test "native :not_found for the missing file and the missing library item passes everywhere" do
    for platform <- [:ios, :android], device <- [:simulator, :emulator, :physical] do
      assert run!(%{platform: platform, device: device}, PassNif) == :pass
    end
  end

  test "library not authorized on a phone: the user must grant :media" do
    assert run!(%{platform: :ios, device: :physical}, LibraryDeniedNif) == {:skip, :needs_user}

    assert run!(%{platform: :android, device: :physical}, LibraryDeniedNif) ==
             {:skip, :needs_user}
  end

  test "library not authorized on a simulator/emulator: a skip that names the native status" do
    sim = %{platform: :ios, device: :simulator}

    for status <- ["not_determined", "denied", "restricted"] do
      answer = ~s({"error":"permission","authorization":"#{status}"})
      assert {:skip, reason} = run_with(LibraryAnswerNif, sim, :library_answer, answer)
      assert reason =~ "ph://mob_photos-selftest-no-such-asset"
      assert reason =~ "PHPhotoLibrary read-write authorization is #{status} on this simulator"
      assert reason =~ "ignores on iOS 26.x"
    end

    # An older iOS NIF without the status field.
    assert {:skip, older} = run_with(LibraryAnswerNif, sim, :library_answer, @permission)
    assert older =~ "authorization is not granted"

    assert {:skip, android} = run!(%{platform: :android, device: :emulator}, LibraryDeniedNif)
    assert android =~ "content://media/external/images/media/"
    assert android =~ "MediaStore refused the read on this emulator"
  end

  test "the stub's nif_not_loaded fails, naming the NIF" do
    assert {:fail, reason} = run!(%{platform: :ios, device: :simulator}, NotLoadedNif)
    assert reason =~ "mob_photos_nif is not linked"
    assert reason =~ "nif_not_loaded"
  end

  test "on a host with no native library linked the real run/1 fails instead of raising" do
    assert {:fail, reason} = SelfTest.run(%{platform: :android, device: :emulator})
    assert reason =~ "mob_photos_nif is not linked"
    assert Mob.Plugin.SelfTest.result?({:fail, reason})
  end

  test "an unregistered Kotlin bridge fails and says so" do
    assert {:fail, reason} = run!(%{platform: :android, device: :emulator}, UnregisteredNif)
    assert reason =~ "MobPhotosBridge.register() never ran"
  end

  test "any other answer for the missing file fails, saying what came back" do
    ctx = %{platform: :android, device: :emulator}

    assert {:fail, found} =
             run_with(FileAnswerNif, ctx, :file_answer, ~s({"path":"/c/t.jpg","width":1}))

    assert found =~ "/mob_photos-selftest-no-such-image.jpg"
    assert found =~ "{:ok, %{"
    assert found =~ "expected {:error, :not_found}"

    assert {:fail, denied} = run_with(FileAnswerNif, ctx, :file_answer, @permission)
    assert denied =~ "answered {:error, :permission}"

    assert {:fail, no_context} =
             run_with(
               FileAnswerNif,
               ctx,
               :file_answer,
               ~s({"error":"mob_photos bridge has no context yet"})
             )

    assert no_context =~ "no context yet"

    assert {:fail, timeout} = run_with(FileAnswerNif, ctx, :file_answer, ~s({"error":"timeout"}))
    assert timeout =~ "no {:mob_photos_thumbnail, json} reply within 5 s"

    assert {:fail, atom} = run!(ctx, ErrorAtomNif)
    assert atom =~ "photo_thumbnail/2 returned :error"
  end

  test "any other answer for the missing library item fails" do
    for {platform, device} <- [ios: :simulator, ios: :physical, android: :physical],
        answer <- [~s({"error":"unsupported"}), ~s({"path":"/c/t.jpg"}), ~s({"error":"boom"})] do
      ctx = %{platform: platform, device: device}
      assert {:fail, reason} = run_with(LibraryAnswerNif, ctx, :library_answer, answer)
      assert reason =~ "missing library item"
      assert reason =~ "expected {:error, :not_found}"
    end

    assert run_with(
             LibraryAnswerNif,
             %{platform: :ios, device: :simulator},
             :library_answer,
             @not_found
           ) ==
             :pass
  end
end
