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

    # Without it MediaStore redacts EXIF GPS from every stream: thumbnail/2
    # would silently never report a location.
    test "declares ACCESS_MEDIA_LOCATION so thumbnails keep EXIF GPS", %{manifest: m} do
      assert "android.permission.ACCESS_MEDIA_LOCATION" in m.android.permissions
    end

    test "iOS links PhotosUI (picker) + Photos (permission/enumeration) and a plist usage string",
         %{manifest: m} do
      assert "PhotosUI" in m.ios.frameworks
      assert "Photos" in m.ios.frameworks
      # PHPhotoLibrary authorization requires NSPhotoLibraryUsageDescription.
      assert Map.has_key?(m.ios.plist_keys, "NSPhotoLibraryUsageDescription")
    end

    test "iOS links the frameworks the thumbnail path's symbols live in", %{manifest: m} do
      # kCGImage* constants + CGImageSource/Destination, and UTTypeJPEG.
      assert "ImageIO" in m.ios.frameworks
      assert "UniformTypeIdentifiers" in m.ios.frameworks
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

      for fa <- [photos_pick: 2, media_list: 1, photo_thumbnail: 2] do
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

      assert_raise ErlangError, ~r/nif_not_loaded/, fn ->
        MobPhotos.thumbnail("/tmp/x.jpg")
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

  describe "thumbnail_request/2 (option normalisation + source classification)" do
    test "defaults to a 1280 px longest side at quality 80" do
      assert {:ok, %{"max_size" => 1280, "quality" => 80}} =
               MobPhotos.thumbnail_request("/sdcard/DCIM/Camera/a.jpg", [])
    end

    test "max_size and quality override the defaults" do
      assert {:ok, %{"max_size" => 512, "quality" => 95}} =
               MobPhotos.thumbnail_request("/a.jpg", max_size: 512, quality: 95)
    end

    test "an absolute path is a file source, passed through verbatim" do
      assert {:ok, %{"kind" => "file", "source" => "/data/user/0/app/cache/mob_pick_1.jpg"}} =
               MobPhotos.thumbnail_request("/data/user/0/app/cache/mob_pick_1.jpg", [])
    end

    test "a file:// URL becomes its decoded local path" do
      assert {:ok, %{"kind" => "file", "source" => "/tmp/My Photo.jpg"}} =
               MobPhotos.thumbnail_request("file:///tmp/My%20Photo.jpg", [])

      assert {:ok, %{"kind" => "file", "source" => "/tmp/a.jpg"}} =
               MobPhotos.thumbnail_request("file://localhost/tmp/a.jpg", [])
    end

    test "a file:// URL naming another host is rejected" do
      assert {:error, "invalid source" <> _} =
               MobPhotos.thumbnail_request("file://server/share/a.jpg", [])
    end

    test "a content:// URI is kept whole (the Android bridge parses it)" do
      uri = "content://media/external/images/media/1000000021"

      assert {:ok, %{"kind" => "content", "source" => ^uri}} =
               MobPhotos.thumbnail_request(uri, [])
    end

    test "a ph:// id is an asset source carrying the bare local identifier" do
      assert {:ok,
              %{"kind" => "asset", "source" => "9F983DBA-EC35-42B8-8773-B597CF782EDD/L0/001"}} =
               MobPhotos.thumbnail_request("ph://9F983DBA-EC35-42B8-8773-B597CF782EDD/L0/001", [])
    end

    test "relative paths, empty ids and other schemes are errors, not NIF calls" do
      for bad <- ["IMG_1.jpg", "", "ph://", "content://", "https://example.com/a.jpg"] do
        assert {:error, "invalid source" <> _} = MobPhotos.thumbnail_request(bad, []),
               "expected #{inspect(bad)} to be rejected"
      end
    end

    test "out-of-range or non-integer options raise" do
      for opts <- [
            [max_size: 0],
            [max_size: -5],
            [max_size: 12.5],
            [quality: 0],
            [quality: 101],
            [quality: "80"]
          ] do
        assert_raise ArgumentError, fn -> MobPhotos.thumbnail_request("/a.jpg", opts) end
      end
    end

    test "unknown options raise (no silent typos like :max)" do
      assert_raise ArgumentError, fn -> MobPhotos.thumbnail_request("/a.jpg", max: 100) end
    end

    test "the boundary qualities 1 and 100 are accepted" do
      assert {:ok, %{"quality" => 1}} = MobPhotos.thumbnail_request("/a.jpg", quality: 1)
      assert {:ok, %{"quality" => 100}} = MobPhotos.thumbnail_request("/a.jpg", quality: 100)
    end
  end

  describe "decode_thumbnail_result/1 (native reply -> public result)" do
    @full ~s({"path":"/c/mob_thumb_ab.jpg","width":960,"height":1280,"orig_width":3000,
    "orig_height":4000,"mime":"image/jpeg","size":196758,"exif_datetime":"2024:05:01 12:34:56",
    "exif_offset":"-07:00","date_taken_ms":1714592096000,"latitude":49.2827,
    "longitude":-123.1207,"altitude":70.5,"make":"TestCam","model":"Probe 1"})

    test "a full reply decodes to every documented key" do
      assert {:ok, info} = MobPhotos.decode_thumbnail_result(@full)

      assert info == %{
               path: "/c/mob_thumb_ab.jpg",
               width: 960,
               height: 1280,
               orig_width: 3000,
               orig_height: 4000,
               mime: "image/jpeg",
               size: 196_758,
               taken_at: "2024-05-01T12:34:56-07:00",
               latitude: 49.2827,
               longitude: -123.1207,
               altitude: 70.5,
               make: "TestCam",
               model: "Probe 1"
             }
    end

    test "a minimal reply has nil for every missing or null metadata field" do
      json = ~s({"path":"/c/t.jpg","width":640,"height":480,"orig_width":640,"orig_height":480,
      "mime":null,"size":null,"make":null})

      assert {:ok, info} = MobPhotos.decode_thumbnail_result(json)

      for key <- [:mime, :size, :taken_at, :latitude, :longitude, :altitude, :make, :model] do
        assert Map.fetch!(info, key) == nil, "#{key} should be nil"
      end
    end

    test "the documented error codes become atoms; anything else stays a string" do
      assert {:error, :not_found} = MobPhotos.decode_thumbnail_result(~s({"error":"not_found"}))

      assert {:error, :unsupported} =
               MobPhotos.decode_thumbnail_result(~s({"error":"unsupported"}))

      assert {:error, :permission} = MobPhotos.decode_thumbnail_result(~s({"error":"permission"}))
      assert {:error, :timeout} = MobPhotos.decode_thumbnail_result(~s({"error":"timeout"}))

      assert {:error, "out of memory decoding the image"} =
               MobPhotos.decode_thumbnail_result(~s({"error":"out of memory decoding the image"}))
    end

    defp taken_at(fields) do
      base = %{"path" => "/t.jpg", "width" => 1, "height" => 1}
      json = base |> Map.merge(fields) |> :json.encode() |> IO.iodata_to_binary()
      {:ok, %{taken_at: taken_at}} = MobPhotos.decode_thumbnail_result(json)
      taken_at
    end

    test "taken_at: EXIF time with its offset wins over the platform date" do
      assert taken_at(%{
               "exif_datetime" => "2024:05:01 12:34:56",
               "exif_offset" => "+02:00",
               "date_taken_ms" => 1
             }) == "2024-05-01T12:34:56+02:00"
    end

    test "taken_at: without an offset the platform's absolute date (UTC) wins" do
      assert taken_at(%{
               "exif_datetime" => "2024:05:01 12:34:56",
               "date_taken_ms" => 1_714_592_096_789
             }) ==
               "2024-05-01T19:34:56Z"
    end

    test "taken_at: bare EXIF local time when that is all there is" do
      assert taken_at(%{"exif_datetime" => "2023:07:14 09:00:00"}) == "2023-07-14T09:00:00"
    end

    test "taken_at: the platform date alone" do
      assert taken_at(%{"date_taken_ms" => 1_714_592_096_000}) == "2024-05-01T19:34:56Z"
    end

    test "taken_at: a clockless camera's zero/blank EXIF date is ignored" do
      assert taken_at(%{"exif_datetime" => "0000:00:00 00:00:00", "exif_offset" => "+00:00"}) ==
               nil

      assert taken_at(%{"exif_datetime" => "    :  :     :  :  "}) == nil

      assert taken_at(%{
               "exif_datetime" => "0000:00:00 00:00:00",
               "date_taken_ms" => 1_714_592_096_000
             }) ==
               "2024-05-01T19:34:56Z"
    end

    test "taken_at: a malformed offset is dropped, not glued onto the time" do
      assert taken_at(%{"exif_datetime" => "2023:07:14 09:00:00", "exif_offset" => "  :  "}) ==
               "2023-07-14T09:00:00"
    end

    test "taken_at: a zero/negative or out-of-range platform date means unknown" do
      assert taken_at(%{"date_taken_ms" => 0}) == nil
      assert taken_at(%{"date_taken_ms" => -1}) == nil
      assert taken_at(%{"date_taken_ms" => 1_714_592_096_000_000_000}) == nil
    end

    test "taken_at: an offset outside the real UTC range is dropped" do
      assert taken_at(%{"exif_datetime" => "2023:07:14 09:00:00", "exif_offset" => "+99:99"}) ==
               "2023-07-14T09:00:00"
    end

    # Android's photo picker hands out copies with the GPS tags zeroed.
    test "a (0, 0) GPS fix (redacted/placeholder) is reported as no location, altitude included" do
      json = ~s({"path":"/t.jpg","width":1,"height":1,"latitude":0,"longitude":0,"altitude":0})

      assert {:ok, %{latitude: nil, longitude: nil, altitude: nil}} =
               MobPhotos.decode_thumbnail_result(json)
    end

    test "integer coordinates come back as floats; a lone coordinate is dropped" do
      json =
        ~s({"path":"/t.jpg","width":1,"height":1,"latitude":49,"longitude":-123,"altitude":12})

      assert {:ok, %{latitude: 49.0, longitude: -123.0, altitude: 12.0}} =
               MobPhotos.decode_thumbnail_result(json)

      assert {:ok, %{latitude: nil, longitude: nil}} =
               MobPhotos.decode_thumbnail_result(~s({"path":"/t.jpg","latitude":49.1}))
    end

    test "make/model are trimmed of padding and NULs; blank becomes nil" do
      json = ~s({"path":"/t.jpg","make":"Canon\\u0000\\u0000 ","model":"   "})
      assert {:ok, %{make: "Canon", model: nil}} = MobPhotos.decode_thumbnail_result(json)
    end
  end

  describe "Android bridge enumeration (source-level — JNI not exercisable in mix test)" do
    setup do
      {:ok, m} = Manifest.load(@plugin_dir)
      %{src: File.read!(Path.join(@plugin_dir, m.android.bridge_kt))}
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
  end

  describe "public API surface (extraction parity with old Mob.Photos)" do
    test "exports the full extracted surface" do
      exports = MobPhotos.__info__(:functions)

      for fa <- [
            pick: 1,
            pick: 2,
            list_media: 1,
            list_media: 2,
            list_media_opts: 1,
            thumbnail: 1,
            thumbnail: 2
          ] do
        assert fa in exports, "#{inspect(fa)} missing from MobPhotos"
      end
    end
  end
end
