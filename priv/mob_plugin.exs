%{
  name: :mob_photos,
  mob_version: "~> 0.6",
  plugin_spec_version: 1,
  description:
    "Photo/video library picker + MediaStore enumeration — extracted from mob core in Wave 2",
  nifs: [
    # iOS: Objective-C NIF — PHPickerViewController (iOS 14+) + the :media
    # permission flow (PHPhotoLibrary). lang: :objc -> compiled as ObjC
    # (-fobjc-arc); platform: :ios so it isn't pulled into the Android build.
    %{module: :mob_photos_nif, native_dir: "priv/native/ios", lang: :objc, platform: :ios},
    # Android: zig NIF bridging to the system Photo Picker (PickVisualMedia /
    # PickMultipleVisualMedia) and MediaStore enumeration (ContentResolver)
    # via the Kotlin MobPhotosBridge.
    %{module: :mob_photos_nif, native_dir: "priv/native/jni", lang: :zig, platform: :android}
  ],
  # Runtime-permission capability OWNED by this plugin: :media. The picker
  # (pick/2) runs out of process and needs no permission, but library
  # ENUMERATION (list_media/2) reads the whole MediaStore / Photos library and
  # genuinely requires READ_MEDIA_IMAGES / READ_MEDIA_VIDEO (Android 33+) or a
  # PHPhotoLibrary authorization (iOS). `Mob.Permissions.request(socket, :media)`
  # pops that dialog. Registered exactly like mob_camera's :camera —
  #   * iOS:     handler self-registered at NIF load
  #              (mob_photos_request_permission -> PHPhotoLibrary
  #              requestAuthorizationForAccessLevel:PHAccessLevelReadWrite)
  #   * Android: cap->permission mapping via MobPhotosBridge implementing
  #              MobPermissionProvider (permissionsFor("media")).
  # NOTE: core also ships a :photo_library capability that maps to the same
  # OS permissions; :media is this plugin's self-contained capability for the
  # enumeration feature so the feature's permission lives with the code that
  # owns it (parity with how mob_camera owns :camera rather than leaning on a
  # core capability). Both end up requesting the same READ_MEDIA_* set on
  # Android; declaring it here is harmless (set-unioned in the manifest merge).
  permissions: [
    %{capability: :media, ios: %{handler: "mob_photos_request_permission"}}
  ],
  android: %{
    bridge_kt: "priv/native/android/MobPhotosBridge.kt",
    bridge_class: "io.mob.photos.MobPhotosBridge",
    # Moved here from the mob_new AndroidManifest template (Media library
    # block). The system Photo Picker itself doesn't require these, but
    # MediaStore enumeration (list_media/2) DOES, and they keep parity with
    # what core shipped (and cover OEM fallback pickers on API <= 32). NOTE:
    # the template scoped READ_EXTERNAL_STORAGE with android:maxSdkVersion="32";
    # plugin permission entries are plain strings today, so that attribute is
    # lost in the merge — harmless (the permission is a no-op on 33+) but worth
    # restoring if the manifest schema grows attribute support.
    permissions: [
      "android.permission.READ_MEDIA_IMAGES",
      "android.permission.READ_MEDIA_VIDEO",
      "android.permission.READ_EXTERNAL_STORAGE"
    ]
  },
  # PHPickerViewController / PHPickerConfiguration / PHPickerResult all live
  # in PhotosUI; PHPhotoLibrary (permission + enumeration) lives in Photos.
  # UIKit/Foundation are implicit. plist_keys: NSPhotoLibraryUsageDescription
  # is required by iOS the moment PHPhotoLibrary authorization is requested
  # (the :media permission flow) — without it the dialog is suppressed. The
  # string is a placeholder the host must replace (App Store review rejects
  # the default text — intentional friction, same gate as mob_camera).
  ios: %{
    frameworks: ["PhotosUI", "Photos"],
    plist_keys: %{
      "NSPhotoLibraryUsageDescription" =>
        "Required by mob_photos to list your photo library — replace this string in your Info.plist"
    }
  }
  # No host_requirements: the picker reads content:// URIs via contentResolver
  # and enumeration queries MediaStore via contentResolver — no AndroidManifest
  # fragment needed from the host.
}
