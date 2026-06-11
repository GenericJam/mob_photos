// mob_photos plugin — Android bridge (system Photo Picker).
//
// Extracted from mob-core's MobBridge photos_pick / handlePhotosResult plus
// MainActivity's photosPickerLauncher. Lives in the plugin's own package;
// MobPluginBootstrap.registerAll() calls register() at startup and hands it
// the Activity (MobActivityAware). It is NOT a MobPermissionProvider — the
// Photo Picker runs out of process, so no runtime permission dialog exists.
//
// The native thunks (nativeRegister + the two deliver hooks) are exported
// directly from the sibling zig NIF mob_photos_nif.zig.
//
// DESIGN NOTE vs core: core pre-registered the launcher in MainActivity's
// onCreate via registerForActivityResult (MainActivity.kt.eex:42-53), but
// that convenience API must run before the host reaches STARTED — a
// late-bound plugin can't meet that. mob's MainActivity is a
// ComponentActivity (Compose host), not a FragmentActivity, so a headless
// Fragment can't attach either. Instead this bridge registers directly on
// the ComponentActivity's ActivityResultRegistry (register(key, contract,
// callback) is callable any time) and unregisters in the callback —
// self-contained, no host MainActivity changes. (Same pattern as
// mob_camera's MobCameraBridge.)
//
// CONTRACT GOTCHA: PickMultipleVisualMedia(maxItems) throws when
// maxItems < 2, so max == 1 uses the single-item PickVisualMedia() contract
// instead — both feed the same handlePhotosResult. Core sidestepped this by
// ignoring max entirely (its pre-registered launcher always used the
// default multi-pick); honoring max here is a deliberate fidelity
// improvement over core, message shapes unchanged.
package io.mob.photos

import android.app.Activity
import android.net.Uri
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.ActivityResultRegistryOwner
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import java.io.File
import java.lang.ref.WeakReference
import java.util.concurrent.atomic.AtomicLong

object MobPhotosBridge : io.mob.plugin.MobActivityAware {
    private var activityRef: WeakReference<Activity>? = null

    @JvmStatic external fun nativeRegister()

    // {:photos, :cancelled}
    @JvmStatic external fun nativeDeliverPhotosCancelled(pid: Long)

    // {:mob_file_result, "photos", "picked", json} — decoded by core
    // Mob.Screen into {:photos, :picked, items} (lib/mob/screen.ex:343-391)
    @JvmStatic external fun nativeDeliverPhotosPicked(
        pid: Long,
        json: String,
    )

    @JvmStatic fun register() = nativeRegister()

    override fun setActivity(activity: Activity) {
        activityRef = WeakReference(activity)
    }

    private val pickSeq = AtomicLong(0L)

    // ── Pick (photos / videos) ────────────────────────────────────────────
    // Signature matches what the zig NIF calls: (JLjava/lang/String;)V —
    // core passed max as a decimal string (mob_nif.zig:2553-2566).
    @JvmStatic
    fun photos_pick(
        pid: Long,
        maxStr: String,
    ) {
        val max = maxStr.toIntOrNull() ?: 1
        val activity =
            activityRef?.get() ?: run {
                nativeDeliverPhotosCancelled(pid)
                return
            }
        val owner =
            activity as? ActivityResultRegistryOwner ?: run {
                nativeDeliverPhotosCancelled(pid)
                return
            }
        val request = PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageAndVideo)
        val key = "mob_photos_${pickSeq.incrementAndGet()}"
        if (max >= 2) {
            var launcher: ActivityResultLauncher<PickVisualMediaRequest>? = null
            launcher =
                owner.activityResultRegistry.register(
                    key,
                    ActivityResultContracts.PickMultipleVisualMedia(max),
                ) { uris: List<Uri> ->
                    handlePhotosResult(pid, uris)
                    launcher?.unregister()
                }
            launcher.launch(request)
        } else {
            // PickMultipleVisualMedia(maxItems) requires maxItems >= 2 — for a
            // single item use the dedicated single-pick contract.
            var launcher: ActivityResultLauncher<PickVisualMediaRequest>? = null
            launcher =
                owner.activityResultRegistry.register(
                    key,
                    ActivityResultContracts.PickVisualMedia(),
                ) { uri: Uri? ->
                    handlePhotosResult(pid, listOfNotNull(uri))
                    launcher?.unregister()
                }
            launcher.launch(request)
        }
    }

    // Result processing copied from core MobBridge.handlePhotosResult
    // (MobBridge.kt.eex:722-741): copy each content URI into a cacheDir tmp
    // file on a background thread, then deliver the JSON item array. The
    // JSON shape ({"path","type","width":0,"height":0}, type as a string,
    // dimensions not probed) is core parity — Mob.Screen atomizes only the
    // keys, so Android items reach user code with string type values.
    internal fun handlePhotosResult(
        pid: Long,
        uris: List<Uri>,
    ) {
        if (uris.isEmpty()) {
            nativeDeliverPhotosCancelled(pid)
            return
        }
        val activity =
            activityRef?.get() ?: run {
                nativeDeliverPhotosCancelled(pid)
                return
            }
        Thread {
            try {
                val items =
                    uris.mapIndexed { i, uri ->
                        val ext = if (uri.toString().contains("video")) "mp4" else "jpg"
                        val tmp = File(activity.cacheDir, "mob_pick_${System.currentTimeMillis()}_$i.$ext")
                        activity.contentResolver.openInputStream(uri)?.use { it.copyTo(tmp.outputStream()) }
                        val type = if (ext == "mp4") "video" else "image"
                        """{"path":"${tmp.absolutePath}","type":"$type","width":0,"height":0}"""
                    }
                val json = "[${items.joinToString(",")}]"
                nativeDeliverPhotosPicked(pid, json)
            } catch (e: Exception) {
                nativeDeliverPhotosCancelled(pid)
            }
        }.start()
    }
}
