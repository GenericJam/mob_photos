# mob_photos — Agent Instructions

**Read [`AGENTS.md`](AGENTS.md) first**, then [`~/code/mob/AGENTS.md`](../mob/AGENTS.md) for the system view. Together they cover the plugin's two access modes (out-of-process picker vs. permission-gated `MediaStore` enumeration), the anatomy, the peer plugins mob_photos is NOT ([mob_camera](https://hexdocs.pm/mob_camera), [mob_video](https://hexdocs.pm/mob_video), [mob_scanner](https://hexdocs.pm/mob_scanner)), and the pre-empt-failure rules. See [`~/code/mob/MOB_PLUGINS.md`](../mob/MOB_PLUGINS.md) for the manifest schema.

> **Keep AGENTS.md up to date** when you change the picker/enumeration surface, delivery message shapes, or hit a new gotcha — fix it in the same commit, not in a follow-up. Out-of-date guidance there causes wrong decisions downstream.

## Pre-commit checklist

Same as mob core:

```bash
mix test
mix format
mix credo --strict       # includes ExSlop + jump_credo_checks
```

Native changes (`.m` / `.zig` / `.kt`) aren't exercised by `mix test` — they need a `mix mob.deploy --native` of a host app (e.g. `mob_plugin_demo`) and a device check before committing. `mix test` covers the manifest, the NIF stub, and grep-level assertions on the native sources; the JNI/ObjC never actually links here.

The pre-push hook (`.githooks/pre-push`, activated via `git config core.hooksPath .githooks`) runs `mix format --check-formatted`, `mix credo --strict`, and `mix compile --warnings-as-errors` on every push, plus the full test suite when `mix.exs` changes (release preflight).

## Releases

`@version` in `mix.exs` on master triggers `.github/workflows/release.yml` (tag + GitHub Release + Hex publish, each step idempotent). Signed release: CI regenerates an Ed25519 signature against the committed `priv/mob_plugin.pub` on every publish — generated apps trust the shared mob first-party key so the plugin clears the signature gate without `acknowledge_unsafe_plugins`. Do NOT bump versions without explicit permission. See [`~/code/mob/RELEASE.md`](../mob/RELEASE.md) for the full trigger model.
