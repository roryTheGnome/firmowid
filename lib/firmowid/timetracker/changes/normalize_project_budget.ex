defmodule Firmowid.Timetracker.Changes.NormalizeProjectBudget do
  @moduledoc """
  Clears budget fields that do not apply after `budget_kind` or `budget_scope` changes.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> clear_budget_when_absent()
    |> clear_engagement_dates_for_monthly_scope()
  end

  defp clear_budget_when_absent(changeset) do
    if is_nil(Ash.Changeset.get_attribute(changeset, :budget_kind)) do
      changeset
      |> Ash.Changeset.force_change_attribute(:budget_scope, nil)
      |> Ash.Changeset.force_change_attribute(:budget_limit, nil)
      |> Ash.Changeset.force_change_attribute(:budget_engagement_starts_on, nil)
      |> Ash.Changeset.force_change_attribute(:budget_engagement_ends_on, nil)
    else
      changeset
    end
  end

  defp clear_engagement_dates_for_monthly_scope(changeset) do
    if Ash.Changeset.get_attribute(changeset, :budget_scope) == :monthly do
      changeset
      |> Ash.Changeset.force_change_attribute(:budget_engagement_starts_on, nil)
      |> Ash.Changeset.force_change_attribute(:budget_engagement_ends_on, nil)
    else
      changeset
    end
  end
end