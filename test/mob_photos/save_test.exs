defmodule MobPhotos.SaveTest do
  # Changes the :mob_photos app env (the NIF module, the fake's answers).
  use ExUnit.Case, async: false

  alias MobPhotos.Fake

  @socket %Mob.Socket{}

  setup do
    tmp =
      Path.join(System.tmp_dir!(), "mob_photos_save_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)
    Application.put_env(:mob_photos, :nif, Fake)
    Application.put_env(:mob_photos, :fake_library_dir, Path.join(tmp, "library"))
    Fake.reset()

    on_exit(fn ->
      Application.delete_env(:mob_photos, :nif)
      Application.delete_env(:mob_photos, :fake_library_dir)
      Application.delete_env(:mob_photos, :fake_save_answer)
      File.rm_rf!(tmp)
    end)

    drawing = Path.join(tmp, "drawing.png")
    File.write!(drawing, "png bytes")
    %{tmp: tmp, drawing: drawing}
  end

  describe "save/3" do
    test "copies the file into the library and answers :saved with its uri", %{drawing: drawing} do
      assert MobPhotos.save(@socket, drawing) == @socket
      assert_receive {:photos, :saved, %{path: ^drawing, uri: "fake://" <> copy}}
      assert File.read!(copy) == "png bytes"
      assert File.read!(drawing) == "png bytes"
      assert Fake.saved() == ["drawing.png"]
    end

    test "album: and name: place and name the copy; a clash is renamed", %{drawing: drawing} do
      MobPhotos.save(@socket, drawing, album: "Bezalel", name: "Exodus 31.png")
      MobPhotos.save(@socket, drawing, album: "Bezalel", name: "Exodus 31.png")
      assert_receive {:photos, :saved, _}
      assert_receive {:photos, :saved, _}
      assert Fake.saved() == ["Bezalel/Exodus 31 (1).png", "Bezalel/Exodus 31.png"]
    end

    test "a refused library answers :save_failed with :permission_denied", %{drawing: drawing} do
      Fake.set_save_answer(:permission_denied)
      MobPhotos.save(@socket, drawing)
      assert_receive {:photos, :save_failed, %{path: ^drawing, reason: :permission_denied}}
      assert Fake.saved() == []
    end

    test "a platform message is passed through as the reason", %{drawing: drawing} do
      Fake.set_save_answer({:error, "disk full"})
      MobPhotos.save(@socket, drawing)
      assert_receive {:photos, :save_failed, %{reason: "disk full"}}
    end

    test "a missing file fails with :not_found without reaching the native side", %{tmp: tmp} do
      missing = Path.join(tmp, "gone.jpg")
      MobPhotos.save(@socket, missing)
      assert_receive {:photos, :save_failed, %{path: ^missing, reason: :not_found}}
      assert Fake.saved() == []
    end

    test "a file that is neither a picture nor a video fails with :unsupported", %{tmp: tmp} do
      notes = Path.join(tmp, "notes.txt")
      File.write!(notes, "text")
      MobPhotos.save(@socket, notes)
      assert_receive {:photos, :save_failed, %{reason: :unsupported}}
    end

    test "an album or name that could escape its folder raises", %{drawing: drawing} do
      for bad <- ["", "  ", ".", "..", "a/b", "../x", "a\\b"] do
        assert_raise ArgumentError, fn -> MobPhotos.save(@socket, drawing, album: bad) end
        assert_raise ArgumentError, fn -> MobPhotos.save(@socket, drawing, name: bad) end
      end

      assert_raise ArgumentError, fn -> MobPhotos.save(@socket, drawing, folder: "x") end
    end

    test "a reply the NIF returns at once (nothing queued) still reaches the caller", %{
      drawing: drawing
    } do
      defmodule Unregistered do
        def photo_save(_receiver, _json), do: ~s({"error":"mob_photos bridge not registered"})
      end

      Application.put_env(:mob_photos, :nif, Unregistered)
      MobPhotos.save(@socket, drawing)
      assert_receive {:photos, :save_failed, %{reason: "mob_photos bridge not registered"}}
    end
  end

  describe "save_request/2" do
    test "the type and MIME come from the extension, case-insensitively", %{tmp: tmp} do
      for {file, type, mime} <- [
            {"a.JPG", "image", "image/jpeg"},
            {"b.png", "image", "image/png"},
            {"c.heic", "image", "image/heic"},
            {"d.MOV", "video", "video/quicktime"},
            {"e.mp4", "video", "video/mp4"}
          ] do
        path = Path.join(tmp, file)
        File.write!(path, "x")

        assert {:ok, %{"type" => ^type, "mime" => ^mime, "name" => ^file, "album" => ""}} =
                 MobPhotos.save_request(path, [])
      end
    end
  end

  describe "decode_save_result/2" do
    test "a uri is :saved; the documented error codes become atoms" do
      assert MobPhotos.decode_save_result(
               "/p.png",
               ~s({"uri":"content://media/external/images/media/7"})
             ) ==
               {:photos, :saved,
                %{path: "/p.png", uri: "content://media/external/images/media/7"}}

      assert {:photos, :save_failed, %{reason: :permission_denied}} =
               MobPhotos.decode_save_result("/p.png", ~s({"error":"permission_denied"}))

      assert {:photos, :save_failed, %{reason: :not_found}} =
               MobPhotos.decode_save_result("/p.png", ~s({"error":"not_found"}))

      assert {:photos, :save_failed, %{reason: "The operation couldn’t be completed."}} =
               MobPhotos.decode_save_result(
                 "/p.png",
                 ~s({"error":"The operation couldn’t be completed."})
               )
    end
  end
end
