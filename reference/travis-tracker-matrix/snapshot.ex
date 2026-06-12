defmodule TravisTracker.Matrix.Snapshot do
  @moduledoc """
  Normalizes a display snapshot into the shape the renderers expect: atom keys
  and epoch-millisecond integers for all datetime fields. Accepts the preview
  fixture maps (and, later, the live Display.Snapshot struct). Recurses into
  nested flight/position/member maps and lists.
  """
  def normalize(%DateTime{} = dt), do: DateTime.to_unix(dt, :millisecond)

  # Leave bare date/time structs untouched — the renderers never read the
  # naive `_local` fields, and Map.from_struct would corrupt them.
  def normalize(%NaiveDateTime{} = x), do: x
  def normalize(%Date{} = x), do: x
  def normalize(%Time{} = x), do: x

  def normalize(%{__struct__: _} = struct), do: struct |> Map.from_struct() |> normalize()
  def normalize(%{} = map), do: Map.new(map, fn {k, v} -> {k, normalize(v)} end)
  def normalize(list) when is_list(list), do: Enum.map(list, &normalize/1)
  def normalize(other), do: other
end
