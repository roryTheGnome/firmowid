defmodule FirmowidWeb.Invoicing.Utilities.ItemUnit do
  @moduledoc """
  Maps stored invoice item unit codes to locale-aware display labels.

  Stored values (`szt.`, `godz.`) stay Polish for KSeF; only UI labels are translated.
  """

  use Gettext, backend: Firmowid.Gettext

  @spec display_unit(String.t()) :: String.t()
  def display_unit(unit) when unit in ["szt.", "szt"], do: pgettext("invoice item unit", "pcs")
  def display_unit(unit) when unit in ["godz.", "godz"], do: pgettext("invoice item unit", "hrs")
  def display_unit(unit), do: unit
end