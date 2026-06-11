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

    test "declares NO runtime-permission capability (pickers run out of process)",
         %{manifest: m} do
      refute Map.has_key?(m, :permissions)
    end

    test "carries the media-read manifest permissions moved out of the mob_new template",
         %{manifest: m} do
      assert "android.permission.READ_MEDIA_IMAGES" in m.android.permissions
      assert "android.permission.READ_MEDIA_VIDEO" in m.android.permissions
      assert "android.permission.READ_EXTERNAL_STORAGE" in m.android.permissions
    end

    test "iOS needs only the PhotosUI framework and no plist usage strings",
         %{manifest: m} do
      assert m.ios.frameworks == ["PhotosUI"]
      refute Map.has_key?(m.ios, :plist_keys)
    end

    test "has no host requirements (picker reads content URIs, no FileProvider)",
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
    test "the manifest NIF module is the shipped .erl stub and loads on the host" do
      assert Code.ensure_loaded?(:mob_photos_nif)
    end

    test "every NIF the public API calls is exported by the stub at the right arity" do
      exports = :mob_photos_nif.module_info(:exports)

      for fa <- [photos_pick: 2] do
        assert fa in exports, "#{inspect(fa)} missing from mob_photos_nif exports"
      end
    end

    test "host (no native linked) falls back to nif_not_loaded, not a load crash" do
      assert_raise ErlangError, ~r/nif_not_loaded/, fn ->
        :mob_photos_nif.photos_pick(1, ["image"])
      end
    end
  end

  describe "public API surface (extraction parity with old Mob.Photos)" do
    test "exports the full extracted surface" do
      exports = MobPhotos.__info__(:functions)

      for fa <- [pick: 1, pick: 2] do
        assert fa in exports, "#{inspect(fa)} missing from MobPhotos"
      end
    end
  end
end
