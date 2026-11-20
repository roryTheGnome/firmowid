defmodule FirmowidWeb.Invoicing.Utilities.ItemUnit do
  @moduledoc """
  Maps stored invoice item unit codes to locale-aware display labels.

  Stored values (`szt.`, `godz.`) stay Polish for KSeF; only UI labels are translated.
  """

  @pcs_units ["szt.", "szt"]
  @hrs_units ["godz.", "godz"]

  @doc "Select options as `{label, value}` pairs for invoice item unit fields."
  @spec select_options() :: [{String.t(), String.t()}]
  def select_options do
    [
      {display_unit("szt."), "szt."},
      {display_unit("godz."), "godz."}
    ]
  end

  @doc "Alternate labels keyed by the stored unit value for styled selects."
  @spec selected_labels() :: %{String.t() => String.t()}
  def selected_labels do
    Enum.flat_map(@pcs_units, &[{&1, display_unit(&1)}]) ++
      Enum.flat_map(@hrs_units, &[{&1, display_unit(&1)}])
    |> Map.new()
  end

  @spec display_unit(String.t()) :: String.t()
  def display_unit(unit) when unit in @pcs_units,
    do: Gettext.pgettext(Firmowid.Gettext, "invoice item unit", "pcs")

  def display_unit(unit) when unit in @hrs_units,
    do: Gettext.pgettext(Firmowid.Gettext, "invoice item unit", "hrs")

  def display_unit(unit), do: unit
end