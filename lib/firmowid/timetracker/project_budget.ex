defmodule Firmowid.Timetracker.ProjectBudget do
  @moduledoc """
  Computes project budget usage for the active budget period.

  Hours budgets count logged session time in the period. Amount budgets add the
  salary cost of that time, priced like the project page, plus the PLN share of
  tagged cost invoices allocated to the project's analysis tag.

  Only organization admins may read budget configuration or computed usage;
  other members must not see limits, spend, or salary-derived amounts through
  this module.
  """
  alias Firmowid.Analysis
  alias Firmowid.Analysis.CategoryTotals
  alias Firmowid.Invoicing
  alias Firmowid.Payroll
  alias Firmowid.Scope
  alias Firmowid.Timetracker
  alias Firmowid.Timetracker.Project

  @warning_threshold Decimal.new(95)
  @exceeded_threshold Decimal.new(100)

  @type status :: :ok | :warning | :exceeded
  @type period :: %{
          key: String.t(),
          scope: :monthly | :engagement,
          starts_on: Date.t(),
          ends_on: Date.t()
        }
  @type usage :: %{
          kind: :hours | :amount,
          period: period(),
          limit: Decimal.t(),
          used: Decimal.t(),
          remaining: Decimal.t(),
          percent: Decimal.t(),
          status: status()
        }

  @doc """
  Returns budget usage for `project` in the period selected by `reference_date`,
  or `nil` when the project has no budget.

  For monthly budgets the period is the calendar month of `reference_date`. For
  engagement budgets it runs from `budget_engagement_starts_on` to
  `budget_engagement_ends_on`.

  Live surfaces recompute on demand — there is no stored usage row. Inbox and
  admin project views refresh through `Firmowid.Core.Notifiers.InboxChanged`
  when sessions, project budget settings, salary rates, cost invoices, or
  project tags on invoices change. Callers outside admin views should treat
  `nil` as “no budget visible”.
  """
  @spec usage(Project.t(), Date.t(), Scope.t()) :: usage() | nil
  def usage(project, reference_date, scope) do
    with true <- admin_scope?(scope),
         true <- budget_configured?(project) do
      compute_usage(project, reference_date, scope)
    else
      _ -> nil
    end
  end

  @doc """
  Computes budget usage for each project that has one, keyed by project id.
  """
  @spec usage_by_project([Project.t()], Date.t(), Scope.t()) :: %{String.t() => usage()}
  def usage_by_project(projects, reference_date, scope) do
    if admin_scope?(scope) do
      do_usage_by_project(projects, reference_date, scope)
    else
      %{}
    end
  end

  defp do_usage_by_project(projects, reference_date, scope) do
    projects
    |> Enum.filter(&budget_configured?/1)
    |> Map.new(fn project -> {project.id, compute_usage(project, reference_date, scope)} end)
  end

  defp compute_usage(%Project{} = project, reference_date, scope) do
    period = period(project, reference_date)
    limit = project.budget_limit

    used =
      case project.budget_kind do
        :hours -> hours_used(project, period, scope)
        :amount -> amount_used(project, period, scope)
      end

    percent = percent(used, limit)
    remaining = Decimal.sub(limit, used)

    %{
      kind: project.budget_kind,
      period: period,
      limit: limit,
      used: used,
      remaining: remaining,
      percent: percent,
      status: status(percent)
    }
  end

  defp budget_configured?(%Project{budget_kind: kind, budget_limit: limit})
       when kind in [:hours, :amount] and not is_nil(limit), do: true

  defp budget_configured?(_), do: false

  defp admin_scope?(%Scope{actor: %{member: %{role: :admin, organization_id: org_id}}, tenant: org_id}), do: true

  defp admin_scope?(_), do: false

  @doc "Whether `date` falls inside a budget period."
  @spec period_active?(period(), Date.t()) :: boolean()
  def period_active?(%{starts_on: starts_on, ends_on: ends_on}, date) do
    not Date.before?(date, starts_on) and not Date.after?(date, ends_on)
  end

  defp period(%Project{budget_scope: :monthly}, reference_date) do
    month = Date.beginning_of_month(reference_date)

    %{
      key: period_key(month),
      scope: :monthly,
      starts_on: month,
      ends_on: Date.end_of_month(month)
    }
  end

  defp period(%Project{budget_scope: :engagement} = project, _reference_date) do
    %{
      key: "#{project.budget_engagement_starts_on}_#{project.budget_engagement_ends_on}",
      scope: :engagement,
      starts_on: project.budget_engagement_starts_on,
      ends_on: project.budget_engagement_ends_on
    }
  end

  defp period_key(%Date{year: year, month: month}) do
    "#{year}-#{pad(month)}"
  end

  defp pad(value) when value < 10, do: "0#{value}"
  defp pad(value), do: to_string(value)

  defp sessions(project, period, scope) do
    Timetracker.list_sessions!(
      %{
        project_id: project.id,
        started_from: period_start_datetime(period),
        started_to: period_end_datetime(period)
      },
      scope: scope,
      load: [:duration, :member]
    )
  end

  defp period_start_datetime(%{starts_on: starts_on}) do
    DateTime.new!(starts_on, ~T[00:00:00.000000], "Etc/UTC")
  end

  defp period_end_datetime(%{ends_on: ends_on}) do
    ends_on |> Date.add(1) |> DateTime.new!(~T[00:00:00.000000], "Etc/UTC")
  end

  defp hours_used(project, period, scope) do
    project
    |> sessions(period, scope)
    |> Enum.map(& &1.duration)
    |> Enum.sum()
    |> seconds_to_hours()
  end

  defp amount_used(project, period, scope) do
    sessions = sessions(project, period, scope)

    sessions
    |> salary_cost(scope)
    |> Decimal.add(tagged_cost_invoices(project, period, scope))
  end

  defp seconds_to_hours(seconds) do
    seconds
    |> Decimal.new()
    |> Decimal.div(Decimal.new(3600))
  end

  defp salary_cost(sessions, scope) do
    sessions
    |> Enum.group_by(fn session ->
      session.start_datetime |> DateTime.to_date() |> Date.beginning_of_month()
    end)
    |> Enum.map(fn {month, month_sessions} ->
      salaries =
        Payroll.list_salaries!(%{active_at: Date.end_of_month(month)},
          scope: scope,
          load: [:member]
        )

      salary_by_user = Map.new(salaries, &{&1.member.user_id, &1.hourly_rate})
      session_salary_cost(month_sessions, salary_by_user)
    end)
    |> Enum.reduce(Decimal.new(0), &Decimal.add/2)
  end

  defp session_salary_cost(sessions, salary_by_user) do
    sessions
    |> Enum.group_by(& &1.member.user_id)
    |> Enum.map(fn {user_id, user_sessions} ->
      time = user_sessions |> Enum.map(& &1.duration) |> Enum.sum()
      rate = Map.get(salary_by_user, user_id)
      hours = Timetracker.seconds_to_hours(time)
      rate && Decimal.mult(rate, Decimal.new(hours))
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce(Decimal.new(0), &Decimal.add/2)
  end

  defp tagged_cost_invoices(%Project{tag_definition_id: nil}, _period, _scope), do: Decimal.new(0)

  defp tagged_cost_invoices(%Project{tag_definition_id: tag_definition_id}, period, scope) do
    key = {:project, tag_definition_id}

    %{
      date_from: period.starts_on,
      date_to: period.ends_on,
      date_field: :sale_date,
      merge_corrections: true
    }
    |> Invoicing.list_cost_invoices!(
      scope: scope,
      load: [:effective_amount, entity_tags: [:tag_definition]]
    )
    |> Enum.filter(fn invoice ->
      Date.compare(Analysis.entry_month(invoice), period.starts_on) != :lt and
        Date.compare(Analysis.entry_month(invoice), period.ends_on) != :gt
    end)
    |> Enum.map(&project_invoice_share(&1, key))
    |> Enum.reduce(Decimal.new(0), &Decimal.add/2)
  end

  defp project_invoice_share(invoice, key) do
    with {:ok, %Money{} = amount} <- invoice_amount_pln(invoice),
         tags when tags != [] <- invoice.entity_tags do
      amount
      |> Money.to_decimal()
      |> Decimal.abs()
      |> CategoryTotals.split(tags)
      |> Enum.find_value(Decimal.new(0), fn
        %{key: ^key, amount: share} -> share
        _other -> false
      end)
    else
      _ -> Decimal.new(0)
    end
  end

  defp invoice_amount_pln(%{effective_amount: %Money{} = amount}) do
    if Money.to_currency_code(amount) == :PLN,
      do: {:ok, amount},
      else: :skip
  end

  defp invoice_amount_pln(_), do: :skip

  defp percent(_used, limit) when is_nil(limit), do: Decimal.new(0)

  defp percent(used, limit) do
    if Decimal.equal?(limit, 0) do
      Decimal.new(0)
    else
      used
      |> Decimal.div(limit)
      |> Decimal.mult(@exceeded_threshold)
      |> Decimal.round(1)
    end
  end

  defp status(percent) do
    cond do
      Decimal.compare(percent, @exceeded_threshold) == :gt -> :exceeded
      Decimal.compare(percent, @warning_threshold) != :lt -> :warning
      true -> :ok
    end
  end
end
