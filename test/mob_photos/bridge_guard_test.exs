defmodule MobPhotos.BridgeGuardTest do
  # The Android NIF calls into MobPhotosBridge through a jclass and method IDs
  # that nativeRegister caches. If a NIF runs before the bridge registers (or a
  # method-ID lookup failed), calling through a null class or method aborts the
  # VM instead of answering {:error, :bridge_not_registered} (MOB-424). The zig
  # can't run under `mix test`, so this reads the source: every function that
  # makes a JNI Call*Method through the cached class must compare that class
  # and the method ID it passes against null before the call.
  use ExUnit.Case, async: true

  @zig Application.app_dir(:mob_photos, "priv/native/jni/mob_photos_nif.zig")
  @cached_class "g_photos_cls"

  test "every JNI call through the cached bridge class null-checks the class and the method ID first" do
    calls = bridge_calls(File.read!(@zig))
    assert calls != [], "found no Call*Method through #{@cached_class} in #{@zig}"

    offenders =
      calls
      |> Enum.map(fn {function, call} -> unguarded(function, call) end)
      |> Enum.reject(&is_nil/1)

    assert offenders == [],
           "unguarded JNI calls in #{Path.basename(@zig)}:\n  " <>
             Enum.join(offenders, "\n  ")
  end

  # [{function, call}], where call is {:ok, class, method, body_before_call}
  # or {:unparsed, text} for a Call*Method this test can't read.
  defp bridge_calls(source) do
    source = String.replace(source, ~r{//[^\n]*}, "")

    for [function, body] <-
          Regex.scan(~r/^(?:export\s+)?fn\s+(\w+)\((.*?)^\}/ms, source, capture: :all_but_first),
        [{start, _}] <- Regex.scan(~r/Call\w*Method\w*/, body, return: :index),
        call = parse_call(body, start),
        match?({:unparsed, _}, call) or elem(call, 1) == @cached_class do
      {function, call}
    end
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
    missing = Enum.reject([class, method], &null_checked?(before, &1))

    if missing != [],
      do:
        "#{function}: calls #{method} through #{class} without a null check of #{Enum.join(missing, " and ")}"
  end

  defp null_checked?(code, name),
    do: Regex.match?(~r/(?<![\w.])#{Regex.escape(name)}\s*==\s*null\b/, code)
end
