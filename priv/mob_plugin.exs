%{
  name: :mob_photos,
  mob_version: "~> 0.6",
  plugin_spec_version: 1,
  description: "Photo/video library picker — extracted from mob core in Wave 2",
  nifs: [
    # iOS: Objective-C NIF — PHPickerViewController (iOS 14+). lang: :objc ->
    # compiled as ObjC (-fobjc-arc); platform: :ios so it isn't pulled into
    # the Android build.
    %{module: :mob_photos_nif, native_dir: "priv/native/ios", lang: :objc, platform: :ios},
    # Android: zig NIF bridging to the system Photo Picker (PickVisualMedia /
    # PickMultipleVisualMedia) via the Kotlin MobPhotosBridge.
    %{module: :mob_photos_nif, native_dir: "priv/native/jni", lang: :zig, platform: :android}
  ],
  # NO :permissions capability entry on purpose: both pickers run out of
  # process (PHPickerViewController on iOS 14+, the Android system Photo
  # Picker) so no runtime permission dialog is ever shown and there is no
  # handler to register with core's permission registry.
  android: %{
    bridge_kt: "priv/native/android/MobPhotosBridge.kt",
    bridge_class: "io.mob.photos.MobPhotosBridge",
    # Moved here from the mob_new AndroidManifest template (Media library
    # block). The system Photo Picker itself doesn't require these, but they
    # keep parity with what core shipped (and cover OEM fallback pickers on
    # API <= 32). NOTE: the template scoped READ_EXTERNAL_STORAGE with
    # android:maxSdkVersion="32"; plugin permission entries are plain strings
    # today, so that attribute is lost in the merge — harmless (the
    # permission is a no-op on 33+) but worth restoring if the manifest
    # schema grows attribute support.
    permissions: [
      "android.permission.READ_MEDIA_IMAGES",
      "android.permission.READ_MEDIA_VIDEO",
      "android.permission.READ_EXTERNAL_STORAGE"
    ]
  },
  # PHPickerViewController / PHPickerConfiguration / PHPickerResult all live
  # in PhotosUI; UIKit/Foundation are implicit. No plist_keys — the picker
  # needs no usage-description string (out-of-process, no library access).
  ios: %{frameworks: ["PhotosUI"]}
  # No host_requirements: unlike camera capture (FileProvider), the photo
  # picker reads content:// URIs via contentResolver — no AndroidManifest
  # fragment needed from the host.
}
