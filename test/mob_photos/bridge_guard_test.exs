defmodule MobPhotos.BridgeGuardTest do
  # The Android NIF calls into MobPhotosBridge through a jclass and method IDs
  # that nativeRegister caches. If a NIF runs before the bridge registers (or a
  # method-ID lookup failed), calling through a null class or method aborts the
  # VM instead of answering {:error, :bridge_not_registered} (MOB-424). The zig
  # can't run under `mix test`, so these read the source.
  use ExUnit.Case, async: true

  @zig Application.app_dir(:mob_photos, "priv/native/jni/mob_photos_nif.zig")
  @cached_class "g_photos_cls"

  setup_all do
    %{source: @zig |> File.read!() |> String.replace(~r{//[^\n]*}, "")}
  end

  test "every JNI call through the cached bridge class returns early when the class or the method ID is null",
       %{source: source} do
    calls = bridge_calls(source)
    assert calls != [], "found no Call*Method through #{@cached_class} in #{Path.basename(@zig)}"

    offenders =
      calls
      |> Enum.map(fn {function, call} -> unguarded(function, call) end)
      |> Enum.reject(&is_nil/1)

    assert offenders == [],
           "unguarded JNI calls in #{Path.basename(@zig)}:\n  " <> Enum.join(offenders, "\n  ")
  end

  # A failed GetStaticMethodID leaves NoSuchMethodError pending: the next JNI
  # call is undefined and the error is thrown out of register(), so the null
  # method ID the guards check for would never be reached.
  test "every method-ID lookup clears the exception a failed lookup leaves pending",
       %{source: source} do
    lookups =
      Regex.scan(~r/(?:getStaticMethodID\(|GetStaticMethodID\.\?\().*?\);\s*(\S+)/, source,
        capture: :all_but_first
      )

    assert lookups != [], "found no method-ID lookup in #{Path.basename(@zig)}"

    uncleared =
      Enum.reject(lookups, fn [next] -> String.starts_with?(next, "jni.exceptionClear(") end)

    assert uncleared == [],
           "#{length(uncleared)} of #{length(lookups)} getStaticMethodID calls in " <>
             "#{Path.basename(@zig)} are not followed by jni.exceptionClear(jenv)"
  end

  # [{function, call}], where call is {:ok, class, method, body_before_call}
  # or {:unparsed, text} for a Call*Method this test can't read.
  defp bridge_calls(source) do
    for [function, body] <- functions(source),
        [{start, _}] <- Regex.scan(~r/Call\w*Method\w*/, body, return: :index),
        call = parse_call(body, start),
        match?({:unparsed, _}, call) or elem(call, 1) == @cached_class do
      {function, call}
    end
  end

  # Top-level fns end at the first `}` in column 0 (zig fmt layout).
  defp functions(source) do
    Regex.scan(
      ~r/^(?:pub\s+)?(?:export\s+)?(?:inline\s+)?fn\s+(\w+)\((.*?)^\}/ms,
      source,
      capture: :all_but_first
    )
  end

  defp parse_call(body, start) do
    rest = binary_part(body, start, byte_size(body) - start)

    case Regex.run(~r/\ACall\w*Method\w*\.\?\(\s*\w+\s*,\s*(\w+)\s*,\s*([\w.]+)/, rest) do
      [_, class, method] -> {:ok, class, method, binary_part(body, 0, start)}
      nil -> {:unparsed, rest |> String.split("\n") |> hd()}
    end
  end

  defp unguarded(function, {:unparsed, text}),
    do: "#{function}: can't read the class and method of `#{text}`"

  defp unguarded(function, {:ok, class, method, before}) do
    conditions =
      Regex.scan(~r/if\s*\(([^)]*)\)\s*\{?\s*return\b/, before, capture: :all_but_first)

    missing = Enum.reject([class, method], &null_checked?(conditions, &1))

    if missing != [],
      do:
        "#{function}: calls #{method} through #{class} without first returning " <>
          "when #{Enum.join(missing, " or ")} is null"
  end

  # A guard `a == null and b == null` doesn't protect a call when only one is
  # null, so only conditions without `and` count.
  defp null_checked?(conditions, name) do
    Enum.any?(conditions, fn [condition] ->
      not Regex.match?(~r/\band\b/, condition) and
        Regex.match?(~r/(?<![\w.])#{Regex.escape(name)}\s*==\s*null\b/, condition)
    end)
  end
end
