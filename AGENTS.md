# AGENTS.md — orientation for AI agents working on mob_photos

You're in **mob_photos**, a Mob plugin for the OS photo/video library. Two access modes: the system picker (`pick/2`) runs out of process and needs no runtime permission on either platform; library enumeration (`list_media/2`) reads MediaStore/PHPhotoLibrary directly and does need the `:media` permission.

**Also read [`~/code/mob/AGENTS.md`](../mob/AGENTS.md)** for the system view — mob's three-repo topology, plugin manifest schema, `Mob.Composite` / `Mob.Sigil`, how to drive a running app from your session, and the cross-cutting pre-empt-failure rules. This file is mob_photos-specific.

> **Keep this file current.** When you change the picker/enumeration API, add a delivery message shape, or hit a gotcha that would trip the next agent, fix it here in the same commit — not in a follow-up.

## What mob_photos is, in one paragraph

A cross-platform plugin whose public surface is the `MobPhotos` module. `pick/2` opens the OS's own out-of-process picker (`PHPickerViewController` on iOS 14+, `PickMultipleVisualMedia` on Android) — the user chooses individual items and the app only ever sees those items, so no photo-library permission dialog is shown and no usage-description string is needed. `list_media/2` is a different beast: it enumerates the whole library with metadata for an "AI Library Search"-style screen. It queries `MediaStore` via `ContentResolver` on Android (async — a background thread inside the Kotlin bridge posts back to a NIF deliver-thunk); on iOS it currently returns `{:error, :unsupported}`. Enumeration requires the `:media` permission this plugin owns and registers with core's permission registry.

Delivery message shapes (calling `Mob.Screen` receives these in `handle_info/2`):

| Source            | Message                             | Item shape                                               |
|-------------------|-------------------------------------|----------------------------------------------------------|
| `pick/2` success  | `{:photos, :picked, items}`         | `%{path, type, width, height}` — see parity notes below  |
| `pick/2` dismiss  | `{:photos, :cancelled}`             | —                                                        |
| `list_media/2`    | `{:media, :listed, items}`          | atom-keyed `%{uri, display_name, size, date_added, mime_type, type}` |

## What mob_photos is NOT

* **Not [mob_camera](https://hexdocs.pm/mob_camera).** That's direct camera access — photo/video capture, live preview, ML frame streaming — and it owns the `:camera` runtime permission. mob_photos never touches the camera. If you need "let the user take a new photo," you want mob_camera.
* **Not [mob_video](https://hexdocs.pm/mob_video).** That's on-device video processing (clip/probe/thumbnail/extract-audio) over a file the app already has. mob_photos hands you a `path` (picker) or a `content://` URI (enumeration) and stops there.
* **Not [mob_scanner](https://hexdocs.pm/mob_scanner).** That's a full-screen QR/barcode scanner. Different surface, different framework, different permission (camera, not photo library).

## Anatomy of the plugin

* `lib/mob_photos.ex` — `MobPhotos` public API: `pick/2`, `list_media/2`, `list_media_opts/1`. The moduledoc is canonical for delivery message shapes + platform-parity notes; keep it and this file in agreement.
* `lib/mob_photos.ex` also exposes `list_media_opts/1` as a **pure** function so tests can pin defaults + JSON serialisation without going through the NIF. Do not fold it back into `list_media/2`.
* `src/mob_photos_nif.erl` — Erlang NIF stub. `photos_pick/2`, `media_list/1`. `on_load` tolerates a missing native lib (host dev build) — the stubs raise `nif_not_loaded` until the real one links.
* `priv/mob_plugin.exs` — plugin manifest. Declares the ObjC + Zig NIF pair, the `:media` permission capability (iOS handler `mob_photos_request_permission`), Android `READ_MEDIA_*` + `READ_EXTERNAL_STORAGE`, iOS `PhotosUI` + `Photos` frameworks, and the `NSPhotoLibraryUsageDescription` placeholder string.
* `priv/native/ios/mob_photos_nif.m` — Objective-C NIF. `PHPickerViewController` + the `PHPhotoLibrary` authorization flow that backs `:media`. `media_list` is stubbed as `{:error, :unsupported}` — Android is the priority.
* `priv/native/jni/mob_photos_nif.zig` — Zig NIF exposing `photos_pick` + `media_list` to BEAM; delivers via the generic `{:mob_file_result, "media" | "photos", sub, json}` path core decodes into atom-keyed maps.
* `priv/native/android/MobPhotosBridge.kt` — Kotlin bridge (`io.mob.photos.MobPhotosBridge`). Implements `MobPermissionProvider` mapping `"media"` → `READ_MEDIA_IMAGES/VIDEO` (+ pre-33 `READ_EXTERNAL_STORAGE`), launches the picker, and runs the `MediaStore` query off a background `Thread {}` so the BEAM scheduler thread isn't blocked.
* `test/mob_photos_test.exs` — pins manifest shape, NIF stub agreement, `list_media_opts/1` serialisation, and source-level assertions on the JNI zig + Kotlin bridge + iOS `.m` (JNI/ObjC can't run under `mix test`).
* There is no `decisions/` directory here yet — if you need one for a non-obvious tradeoff, follow the mob core convention.

## Cross-repo work

**mob (framework):** delivery paths are shared. The picker uses `{:photos, :picked | :cancelled, ...}` and enumeration piggybacks on the generic `{:mob_file_result, event, sub, json}` decoder that core owns — same code path the picker's `path` copy rides. If you change the delivery envelope here, coordinate with mob core. `:media` is a plugin-owned capability that registers via core's permission registry (`mob_register_permission_handler` on iOS, `MobPermissionProvider` on Android) — same pattern as mob_camera's `:camera`.

**mob_new templates:** the media-read Android permissions used to live in the `mob_new` `AndroidManifest.xml` template. They've moved into this plugin's manifest so the permission lives with the code that owns it. If you add or drop entries from `android.permissions`, check `mob_new` isn't still shipping a stale duplicate.

## Testing

Elixir suite (fast, no device needed):

```bash
mix deps.get
mix test
```

The suite pins the manifest via `MobDev.Plugin.{Manifest, Validator}`, the NIF stub's exports + arities, and source-level assertions on the native files (the JNI/ObjC never actually link under `mix test`, so the tests grep for the key symbols and delivery strings — that's the strongest signal `mix test` can give you here).

**Native paths need a device.** The picker (ObjC + zig + Kotlin) isn't exercised by `mix test`. Real verification is `mix mob.deploy --native` of a host app (typically `mob_plugin_demo`) onto Kevin's Moto G Power 5G 2024 or iPhone SE, then driving the picker via `mix mob.connect` and asserting the message reached the screen's `handle_info`. Simulators are OK for smoke but the Photo Picker sometimes behaves differently than a real device (especially older Android's OEM fallback pickers).

## The pre-empt-failure rules that matter here

1. **The picker needs no permission — enumeration does.** Do not add a permission prompt around `pick/2` "for symmetry." It runs out of process; Apple and Google both designed it so the app can't see anything the user didn't hand it. Prompting is wrong and it teaches users to click through dialogs.
2. **iOS and Android picker items are not the same shape.** iOS items carry `path` + `type` (type as an atom). Android items carry `path`, `type` (a **string**), `width`, `height` — and width/height are always `0` because the picker doesn't probe dimensions. This is inherited platform-parity from core; do not "normalise" it silently. Docs must show both shapes.
3. **`list_media/2` on iOS returns `{:error, :unsupported}` today.** Android is the priority. If a screen calls it on iOS the NIF returns synchronously and no `{:media, :listed, _}` message is ever delivered — screens must not `handle_info` for it and then hang waiting.
4. **`NSPhotoLibraryUsageDescription` is a deliberate friction gate.** The plugin ships a placeholder string that Apple's App Store review rejects on purpose (same as mob_camera). Host apps must replace it in their `Info.plist`. Do not "fix" the placeholder to a plausible-looking string — that would let apps ship without thinking about it.
5. **Enumeration must not block the BEAM scheduler.** The Kotlin `MediaStore` query runs on `Thread {}` and calls `nativeDeliverMediaListed` when done. If you touch the bridge, keep that async boundary — a large library synchronously queried on a NIF thread would freeze the scheduler. `list_media/2`'s `limit:` option defaults to `200`; `0` or negative means "no limit" and the whole result comes back in one message — warn callers off unbounded queries.
6. **The `types:` option is currently ignored by both native sides.** `pick(socket, types: [:image])` will still show videos. Core shipped it that way and the plugin preserves the behaviour; if you wire it up, do both platforms in the same commit and update the moduledoc.
7. **The published package is signed** (shared mob first-party Ed25519 key, regenerated in CI on every release). Do not commit `priv/mob_plugin.pub` changes casually — the CI job cross-checks that `MOB_PLUGIN_SIGN_KEY` matches the committed public key before publish.

## Pre-commit + release

Pre-commit checklist (same gate as mob core):

```bash
mix test
mix format
mix credo --strict       # includes ExSlop + jump_credo_checks
```

Pre-push hook (`.githooks/pre-push`, activate via `git config core.hooksPath .githooks`) runs format / credo / compile on every push, and the full test suite when `mix.exs` changes (release preflight).

Releases: bump `@version` in `mix.exs` on master and `.github/workflows/release.yml` handles tag / GitHub Release / Hex publish. See [`~/code/mob/RELEASE.md`](../mob/RELEASE.md) for the trigger model. Do NOT bump versions without explicit permission.
