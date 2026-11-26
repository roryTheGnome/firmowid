defmodule Firmowid.Payroll.Changes.SkipUnchangedRate do
  @moduledoc """
  Skips inserting a new salary when the member already has the same hourly rate
  starting on the same day, to avoid duplicates in salary history.
  """
  use Ash.Resource.Change

  alias Firmowid.Payroll

  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      member_id = Ash.Changeset.get_attribute(changeset, :member_id)
      new_rate = Ash.Changeset.get_attribute(changeset, :hourly_rate)
      new_starts_at = Ash.Changeset.get_attribute(changeset, :starts_at)

      salary = salary_at(member_id, new_starts_at, context)

      if salary && Decimal.equal?(salary.hourly_rate, new_rate) do
        Ash.Changeset.set_result(changeset, {:ok, salary})
      else
        changeset
      end
    end)
  end

  defp salary_at(member_id, starts_at, context) do
    Payroll.list_salaries!(
      Ash.Context.to_opts(context,
        query: [
          filter: [member_id: member_id, starts_at: starts_at],
          limit: 1
        ]
      )
    )
    |> List.first()
  end
end