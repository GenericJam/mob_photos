//! mob_photos_nif — Android photo/video picker tier-1 ZIG plugin NIF.
//!
//! Extracted from mob-core's `mob_nif.zig`: nif_photos_pick (mob_nif.zig:2553)
//! plus the photos paths of mob_deliver_file_result (mob_nif.zig:2268). The
//! Kotlin side is the plugin-owned bridge class `io.mob.photos.MobPhotosBridge`
//! (system Photo Picker: PickVisualMedia / PickMultipleVisualMedia activity
//! contracts). Pick results arrive back via the exported deliver thunks.
//!
//! Delivered message shapes (exact core parity):
//!   * cancelled -> {:photos, :cancelled}
//!     (core: Kotlin nativeDeliverAtom2(pid, "photos", "cancelled") and the
//!     cancelled branch of mob_deliver_file_result, mob_nif.zig:2288-2291)
//!   * picked    -> {:mob_file_result, "photos", "picked", json_binary}
//!     (core: mob_deliver_file_result, mob_nif.zig:2305-2310 — event/sub/json
//!     all as BINARIES, tagged with the :mob_file_result atom). Core's
//!     Mob.Screen handle_info (lib/mob/screen.ex:343-391) decodes the JSON
//!     and re-dispatches the user-facing {:photos, :picked, items} tuple;
//!     that decoder stays in core (files/audio/scan use it too), and its `_`
//!     fallback produces the same {:photos, :picked, items} even if the
//!     explicit photos branch is ever stripped.
//!
//! Build path: compiled via `addZigObject` from `-Dplugin_zig_nifs`, reaching
//! mob-core ERTS / JNI bindings through `@import("erts")` / `@import("jni")`.
//! `get_jenv` + `g_jvm` are mob-core exports linked into the same `.so`.
const std = @import("std");
const erts = @import("erts");
const jni = @import("jni");

// mob-core exports (linked into the same .so). NOT duplicated.
extern fn get_jenv(attached: *c_int) ?*jni.JNIEnv;
extern var g_jvm: ?*jni.JavaVM;

// ── Plugin-owned bridge-class method-id cache ────────────────────────────
const PhotosMethods = struct {
    photos_pick: jni.JMethodID = null,
};

var g_photos: PhotosMethods = .{};
var g_photos_cls: jni.JClass = null;

// ── nativeRegister thunk — cache the bridge jclass + method id ────────────
export fn Java_io_mob_photos_MobPhotosBridge_nativeRegister(jenv: *jni.JNIEnv, cls: jni.JClass) callconv(.c) void {
    g_photos_cls = jni.newGlobalRef(jenv, cls);
    if (g_photos_cls == null) return;
    g_photos.photos_pick = jni.getStaticMethodID(jenv, cls, "photos_pick", "(JLjava/lang/String;)V");
}

// ── Thread-attach + pid round-trip helpers (mirror mob-core / camera) ─────
inline fn detachIfAttached(attached: c_int) void {
    if (attached != 0) {
        if (g_jvm) |jvm| jni.detachCurrentThread(jvm);
    }
}

inline fn pidToJlong(pid: erts.ErlNifPid) jni.JLong {
    if (@sizeOf(erts.ERL_NIF_TERM) == @sizeOf(jni.JLong)) {
        return @bitCast(pid.pid);
    }
    return @intCast(pid.pid);
}

inline fn pidFromLong(jpid: jni.JLong) erts.ErlNifPid {
    if (@sizeOf(erts.ERL_NIF_TERM) == @sizeOf(jni.JLong)) {
        return .{ .pid = @bitCast(jpid) };
    }
    const low: u32 = @truncate(@as(u64, @bitCast(jpid)));
    return .{ .pid = low };
}

/// Call `MobPhotosBridge.<method>(pid_long, arg)` — async; results land later
/// via the deliver thunks. Returns :ok unconditionally.
fn callBridgePidStr(env: ?*erts.ErlNifEnv, method: jni.JMethodID, pid: erts.ErlNifPid, arg: ?[*:0]const u8) erts.ERL_NIF_TERM {
    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.atom(env, "error");
    const jarg: jni.JString = if (arg) |a| jni.newStringUTF(jenv, a) else null;
    jenv.*.CallStaticVoidMethod.?(jenv, g_photos_cls, method, pidToJlong(pid), jarg);
    if (jarg != null) jni.deleteLocalRef(jenv, jarg);
    detachIfAttached(attached);
    return erts.ok(env);
}

// ── Inbound delivery thunks ───────────────────────────────────────────────

// {:photos, :cancelled} — parity with core's cancelled delivery
// (mob_deliver_file_result cancelled branch, mob_nif.zig:2288-2291).
export fn Java_io_mob_photos_MobPhotosBridge_nativeDeliverPhotosCancelled(
    jenv: *jni.JNIEnv,
    cls: jni.JClass,
    pid_long: jni.JLong,
) callconv(.c) void {
    _ = jenv;
    _ = cls;
    var pid = pidFromLong(pid_long);
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const msg = erts.makeTuple(env, .{ erts.atom(env, "photos"), erts.atom(env, "cancelled") });
    _ = erts.enif_send(null, &pid, env, msg);
}

// {:mob_file_result, "photos", "picked", json_binary} — EXACT replica of
// core's mob_deliver_file_result("photos", "picked", json) non-cancelled
// branch (mob_nif.zig:2305-2310): event + sub + json all delivered as
// binaries under the :mob_file_result tag. Core's Mob.Screen
// (lib/mob/screen.ex:343-391) decodes this into {:photos, :picked, items}.
export fn Java_io_mob_photos_MobPhotosBridge_nativeDeliverPhotosPicked(
    jenv: *jni.JNIEnv,
    cls: jni.JClass,
    pid_long: jni.JLong,
    json: jni.JString,
) callconv(.c) void {
    _ = cls;
    var pid = pidFromLong(pid_long);
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);

    const json_c = jenv.*.GetStringUTFChars.?(jenv, json, null) orelse return;
    defer jenv.*.ReleaseStringUTFChars.?(jenv, json, json_c);

    const event = "photos";
    const sub = "picked";
    const jl = std.mem.len(json_c);

    var eb: erts.ErlNifBinary = undefined;
    var sb: erts.ErlNifBinary = undefined;
    var jb: erts.ErlNifBinary = undefined;
    if (erts.enif_alloc_binary(event.len, &eb) == 0) return;
    if (erts.enif_alloc_binary(sub.len, &sb) == 0) return;
    if (erts.enif_alloc_binary(jl, &jb) == 0) return;
    @memcpy(eb.data[0..event.len], event);
    @memcpy(sb.data[0..sub.len], sub);
    @memcpy(jb.data[0..jl], json_c[0..jl]);

    const msg = erts.makeTuple(env, .{
        erts.atom(env, "mob_file_result"),
        erts.enif_make_binary(env, &eb),
        erts.enif_make_binary(env, &sb),
        erts.enif_make_binary(env, &jb),
    });
    _ = erts.enif_send(null, &pid, env, msg);
}

// ── NIFs ──────────────────────────────────────────────────────────────────

// PARITY: core's nif_photos_pick (mob_nif.zig:2553-2566) reads only argv[0]
// (max), formats it as a decimal STRING, and passes it to the bridge via
// callBridgePidStr; argv[1] (types) is ignored on Android too — the system
// Photo Picker is launched with ImageAndVideo regardless. Arity stays 2 to
// match the .erl stub.
fn nif_photos_pick(env: ?*erts.ErlNifEnv, argc: c_int, argv: [*]const erts.ERL_NIF_TERM) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    var max: c_int = 1;
    _ = erts.enif_get_int(env, argv[0], &max);
    var pid: erts.ErlNifPid = undefined;
    _ = erts.enif_self(env, &pid);
    var max_buf: [16]u8 = @splat(0);
    _ = std.fmt.bufPrint(&max_buf, "{d}", .{max}) catch {};
    return callBridgePidStr(env, g_photos.photos_pick, pid, jni.asCStr(&max_buf));
}

// ── NIF table + init entry point ─────────────────────────────────────────
fn nifLoad(env: ?*erts.ErlNifEnv, priv: *?*anyopaque, info: erts.ERL_NIF_TERM) callconv(.c) c_int {
    _ = env;
    _ = priv;
    _ = info;
    return 0;
}

const nif_funcs = [_]erts.ErlNifFunc{
    .{ .name = "photos_pick", .arity = 2, .fptr = nif_photos_pick, .flags = 0 },
};

var nif_entry: erts.ErlNifEntry = .{
    .major = erts.ERL_NIF_MAJOR_VERSION,
    .minor = erts.ERL_NIF_MINOR_VERSION,
    .name = "mob_photos_nif",
    .num_of_funcs = nif_funcs.len,
    .funcs = &nif_funcs,
    .load = nifLoad,
    .reload = null,
    .upgrade = null,
    .unload = null,
    .vm_variant = erts.ERL_NIF_VM_VARIANT,
    .options = 1,
    .sizeof_ErlNifResourceTypeInit = erts.SIZEOF_ErlNifResourceTypeInit,
    .min_erts = erts.ERL_NIF_MIN_ERTS_VERSION,
};

pub export fn mob_photos_nif_nif_init() callconv(.c) *erts.ErlNifEntry {
    return &nif_entry;
}
