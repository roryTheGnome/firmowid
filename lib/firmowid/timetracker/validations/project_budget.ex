defmodule Firmowid.Timetracker.Validations.ProjectBudget do
  @moduledoc """
  Keeps optional project budget fields consistent.

  Without a budget (`budget_kind` nil) the other budget fields stay empty. With a
  budget, scope and limit are required; engagement dates apply only to engagement
  scope.
  """
  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidChanges

  @impl true
  def validate(changeset, _opts, _context) do
    kind = Ash.Changeset.get_attribute(changeset, :budget_kind)
    scope = Ash.Changeset.get_attribute(changeset, :budget_scope)
    limit = Ash.Changeset.get_attribute(changeset, :budget_limit)
    starts_on = Ash.Changeset.get_attribute(changeset, :budget_engagement_starts_on)
    ends_on = Ash.Changeset.get_attribute(changeset, :budget_engagement_ends_on)

    cond do
      is_nil(kind) and present_budget_fields?(scope, limit, starts_on, ends_on) ->
        {:error,
         InvalidChanges.exception(
           message: "budget scope, limit and engagement dates must be empty without a budget"
         )}

      not is_nil(kind) and is_nil(scope) ->
        {:error, field: :budget_scope, message: "is required when a budget is set"}

      not is_nil(kind) and is_nil(limit) ->
        {:error, field: :budget_limit, message: "is required when a budget is set"}

      scope == :monthly and (not is_nil(starts_on) or not is_nil(ends_on)) ->
        {:error,
         InvalidChanges.exception(message: "monthly budgets cannot have engagement dates")}

      scope == :engagement and (is_nil(starts_on) or is_nil(ends_on)) ->
        {:error, field: :budget_engagement_starts_on, message: "is required for engagement budgets"}

      scope == :engagement and Date.compare(starts_on, ends_on) == :gt ->
        {:error, field: :budget_engagement_ends_on, message: "must be on or after the start date"}

      true ->
        :ok
    end
  end

  defp present_budget_fields?(scope, limit, starts_on, ends_on) do
    not is_nil(scope) or not is_nil(limit) or not is_nil(starts_on) or not is_nil(ends_on)
  end
end