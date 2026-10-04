# Changelog

All notable changes to **mob_photos** are documented here.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning: [SemVer](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

### Added
- **`MobPhotos.thumbnail/2`** (MOB-388): a downscaled, upright JPEG of one
  image in the app's cache dir plus its metadata — `width`/`height`,
  `orig_width`/`orig_height`, `mime`, `size`, `taken_at` (ISO-8601, EXIF
  `DateTimeOriginal` + offset, else the platform capture date),
  `latitude`/`longitude`/`altitude`, `make`/`model`. Takes an absolute path,
  an Android `content://` URI or an iOS `ph://<localIdentifier>`. Synchronous
  for the caller, but the decode runs on native worker threads (a GCD queue,
  a two-thread pool on Android), never on a BEAM scheduler. Options
  `max_size:` (default 1280), `quality:` (default 80), `timeout:` (default
  30 s; iOS cancels a pending iCloud download).
  Android: `BitmapFactory` subsampling + `ExifInterface`, un-redacted GPS via
  `MediaStore.setRequireOriginal`. iOS: ImageIO thumbnails + EXIF/GPS,
  `PHImageManager` + `PHAsset.location`/`creationDate` for `ph://` ids.
- **`list_media/2` on iOS** via `PHAsset` (newest first by `creationDate`,
  `ph://` uris) — same `{:media, :listed, items}` message as Android.
- `list_media/2` items carry `date_taken` (unix ms) and upright
  `width`/`height` on both platforms when known.
- Picker items carry `name` and `size` on both platforms, and upright
  `width`/`height` for images (Android used to report `0`).
- The `:media` capability requests `ACCESS_MEDIA_LOCATION` on Android 10+
  (no extra dialog), declared in the manifest, so thumbnails keep EXIF GPS.

### Fixed
- `list_media(type: :all)` now returns the newest items across images and
  videos; it used to fill the limit with images before looking at videos.
- Android picker: videos picked through the system Photo Picker were saved as
  `.jpg` and reported as `"image"` (the picker URI doesn't contain "video");
  the MIME type from the provider decides now.

## [0.1.3] - 2026-09-30

### Changed
- **Re-signed with plugin envelope v2** (MOB-287). mob_dev 0.7.2+ verifies
  this signature before evaluating the manifest. mob_dev 0.7.0 / 0.7.1 can't
  read v2 signatures and report this release as `invalid signature` —
  upgrade the host app to `{:mob_dev, "~> 0.7.2", only: :dev, runtime: false}`.
  No plugin code changes.

## [0.1.1] - 2026-06-16

### Changed
- Signed release: the published package now carries a verified Ed25519
  signature (shared mob first-party key, regenerated in CI on every
  release). Generated apps trust it via `config :mob, :trusted_plugins`,
  so it clears the plugin signature gate without `acknowledge_unsafe_plugins`.

## [0.1.0] - 2026-06-12

Initial release. System photo/video library picker for Mob apps.

- `MobPhotos.pick/2` opens the OS photo picker and returns the chosen media.
- Extracted from mob core in the 0.7.0 plugin-extraction wave.
- Requires `mob ~> 0.7`.
