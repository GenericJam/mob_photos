defmodule MobPhotosTest do
  use ExUnit.Case, async: true

  alias MobDev.Plugin.{Manifest, Validator}

  @plugin_dir Path.expand("..", __DIR__)

  describe "plugin manifest" do
    setup do
      {:ok, manifest} = Manifest.load(@plugin_dir)
      %{manifest: manifest}
    end

    test "loads and validates clean (round-trips)", %{manifest: m} do
      assert {:ok, ^m} = Manifest.validate(m)
    end

    test "classifies as tier 1 (NIF plugin)", %{manifest: m} do
      assert Manifest.tier(m) == 1
    end

    test "passes the full pre-publish validator (paths, NIF modules)", %{manifest: m} do
      assert %{errors: []} = Validator.validate_plugin(m, @plugin_dir)
    end

    test "declares the cross-platform NIF pattern: one module, both platforms",
         %{manifest: m} do
      assert [ios, android] = m.nifs
      assert ios.module == :mob_photos_nif and ios.platform == :ios and ios.lang == :objc
      assert android.module == :mob_photos_nif and android.platform == :android
      assert android.lang == :zig
    end

    test "owns the :media runtime-permission capability (enumeration needs it)",
         %{manifest: m} do
      assert [%{capability: :media} = entry] = m.permissions
      # iOS self-registers a handler at NIF load (mirrors mob_camera's :camera).
      assert entry.ios.handler == "mob_photos_request_permission"
    end

    test "carries the media-read manifest permissions moved out of the mob_new template",
         %{manifest: m} do
      assert "android.permission.READ_MEDIA_IMAGES" in m.android.permissions
      assert "android.permission.READ_MEDIA_VIDEO" in m.android.permissions
      assert "android.permission.READ_EXTERNAL_STORAGE" in m.android.permissions
    end

    test "iOS links PhotosUI (picker) + Photos (permission/enumeration) and a plist usage string",
         %{manifest: m} do
      assert "PhotosUI" in m.ios.frameworks
      assert "Photos" in m.ios.frameworks
      # PHPhotoLibrary authorization requires NSPhotoLibraryUsageDescription.
      assert Map.has_key?(m.ios.plist_keys, "NSPhotoLibraryUsageDescription")
    end

    test "has no host requirements (picker + enumeration read via contentResolver)",
         %{manifest: m} do
      refute Map.has_key?(m, :host_requirements)
    end

    test "every native source dir + Kotlin bridge the manifest references exists",
         %{manifest: m} do
      for %{native_dir: dir} <- m.nifs do
        assert File.dir?(Path.join(@plugin_dir, dir)), "missing #{dir}"
      end

      assert File.exists?(Path.join(@plugin_dir, m.android.bridge_kt))
    end
  end

  describe "NIF stub agreement" do
    # Guards the .erl stub / manifest, not app code — VacuousTest can't see that.
    # credo:disable-for-next-line Jump.CredoChecks.VacuousTest
    test "the manifest NIF module is the shipped .erl stub and loads on the host" do
      assert Code.ensure_loaded?(:mob_photos_nif)
    end

    # Guards the .erl stub / manifest, not app code — VacuousTest can't see that.
    # credo:disable-for-next-line Jump.CredoChecks.VacuousTest
    test "every NIF the public API calls is exported by the stub at the right arity" do
      exports = :mob_photos_nif.module_info(:exports)

      for fa <- [photos_pick: 2, media_list: 1] do
        assert fa in exports, "#{inspect(fa)} missing from mob_photos_nif exports"
      end
    end

    # Guards the .erl stub / manifest, not app code — VacuousTest can't see that.
    # credo:disable-for-next-line Jump.CredoChecks.VacuousTest
    test "host (no native linked) falls back to nif_not_loaded, not a load crash" do
      assert_raise ErlangError, ~r/nif_not_loaded/, fn ->
        :mob_photos_nif.photos_pick(1, ["image"])
      end

      assert_raise ErlangError, ~r/nif_not_loaded/, fn ->
        :mob_photos_nif.media_list("{}")
      end
    end
  end

  describe "list_media_opts/1 (enumeration option serialisation)" do
    test "defaults to all media kinds, newest 200" do
      assert MobPhotos.list_media_opts([]) == %{"type" => "all", "limit" => 200}
    end

    test "type + limit override their defaults and serialise to strings/ints" do
      assert MobPhotos.list_media_opts(type: :image, limit: 50) ==
               %{"type" => "image", "limit" => 50}

      assert MobPhotos.list_media_opts(type: :video, limit: 0) ==
               %{"type" => "video", "limit" => 0}
    end

    test "the opts map round-trips through :json (what the NIF actually receives)" do
      decoded =
        MobPhotos.list_media_opts(type: :video, limit: 10)
        |> :json.encode()
        |> IO.iodata_to_binary()
        |> :json.decode()

      assert decoded["type"] == "video"
      assert decoded["limit"] == 10
    end
  end

  describe "Android bridge enumeration (source-level — JNI not exercisable in mix test)" do
    setup do
      {:ok, m} = Manifest.load(@plugin_dir)
      %{src: File.read!(Path.join(@plugin_dir, m.android.bridge_kt))}
    end

    test "implements MobPermissionProvider mapping :media -> READ_MEDIA_*", %{src: src} do
      assert src =~ "MobPermissionProvider"
      assert src =~ "permissionsFor"
      assert src =~ ~s(cap == "media")
      assert src =~ "READ_MEDIA_IMAGES"
      assert src =~ "READ_MEDIA_VIDEO"
      # Pre-33 fallback so older devices still get read access.
      assert src =~ "READ_EXTERNAL_STORAGE"
    end

    test "media_list queries MediaStore off the BEAM thread and delivers results", %{src: src} do
      assert src =~ "fun media_list"
      assert src =~ "MediaStore"
      assert src =~ "contentResolver.query"
      # Async delivery on a background thread (the NIF callback is on a BEAM
      # scheduler thread; the query must not block it).
      assert src =~ "Thread {"
      assert src =~ "nativeDeliverMediaListed"
    end

    test "enumeration projects the documented metadata columns", %{src: src} do
      for col <- ["DISPLAY_NAME", "SIZE", "DATE_ADDED", "MIME_TYPE"] do
        assert src =~ col, "media_list projection missing #{col}"
      end
    end
  end

  describe "Android zig NIF (source-level)" do
    setup do
      jni = Path.join(@plugin_dir, "priv/native/jni/mob_photos_nif.zig")
      %{src: File.read!(jni)}
    end

    test "exports media_list NIF + the media-listed deliver thunk", %{src: src} do
      assert src =~ "media_list"
      assert src =~ "nativeDeliverMediaListed"
      # Delivered via the same generic {:mob_file_result, event, sub, json} path
      # the picker uses, with event "media" / sub "listed".
      assert src =~ ~s("media")
      assert src =~ ~s("listed")
      assert src =~ "mob_file_result"
    end
  end

  describe "iOS NIF (source-level)" do
    setup do
      ios = Path.join(@plugin_dir, "priv/native/ios/mob_photos_nif.m")
      %{src: File.read!(ios)}
    end

    test "registers the :media permission handler with core's registry at load", %{src: src} do
      assert src =~ "mob_register_permission_handler"
      assert src =~ "mob_photos_request_permission"
      assert src =~ "PHPhotoLibrary"
      # The manifest's declared iOS handler name must match the symbol the
      # source registers.
      {:ok, m} = Manifest.load(@plugin_dir)
      [%{ios: %{handler: handler}}] = m.permissions
      assert src =~ handler
    end

    test "list_media is stubbed unsupported on iOS (Android is the priority)", %{src: src} do
      assert src =~ "media_list"
      assert src =~ "unsupported"
    end
  end

  describe "public API surface (extraction parity with old Mob.Photos)" do
    test "exports the full extracted surface" do
      exports = MobPhotos.__info__(:functions)

      for fa <- [pick: 1, pick: 2, list_media: 1, list_media: 2, list_media_opts: 1] do
        assert fa in exports, "#{inspect(fa)} missing from MobPhotos"
      end
    end
  end
end
