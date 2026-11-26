defmodule Firmowid.Payroll.Changes.NormalizeStartsAt do
  @moduledoc """
  Stores `starts_at` at UTC midnight of the chosen calendar day.
  """
  use Ash.Resource.Change

  alias Firmowid.Payroll.StartsAt

  @impl true
  def change(changeset, _opts, _context) do
    starts_at =
      changeset
      |> Ash.Changeset.get_attribute(:starts_at)
      |> StartsAt.parse()

    Ash.Changeset.force_change_attribute(changeset, :starts_at, starts_at)
  end
end