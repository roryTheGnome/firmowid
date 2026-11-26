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
  alias Firmowid.Core
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
  @type employee_row :: %{
          id: String.t(),
          user: Core.User.t(),
          time_worked: non_neg_integer(),
          hourly_rate: Decimal.t() | nil,
          cost: Decimal.t() | nil,
          removed_from_project: boolean()
        }
  @type invoice_row :: %{
          id: String.t(),
          seller_display_name: String.t() | nil,
          issue_date: Date.t() | nil,
          share: Decimal.t()
        }
  @type spending_breakdown :: %{
          kind: :hours | :amount,
          period: period(),
          usage: usage(),
          employees: [employee_row()],
          invoices: [invoice_row()],
          total_time_worked: non_neg_integer(),
          total_employee_cost: Decimal.t() | nil,
          total_invoice_cost: Decimal.t()
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

  @doc """
  Returns per-employee and tagged-invoice spending for a budget period, or `nil`
  when the project has no budget or the actor is not an admin.

  Totals match `usage/3` for the same project and reference date.
  """
  @spec spending_breakdown(Project.t(), Date.t(), Scope.t()) :: spending_breakdown() | nil
  def spending_breakdown(project, reference_date, scope) do
    with true <- admin_scope?(scope),
         true <- budget_configured?(project) do
      project = Ash.load!(project, [members: [:user]], scope: scope)
      period = period(project, reference_date)
      sessions = sessions(project, period, scope)

      employees = employee_rows(project, sessions, period, scope)
      total_time_worked = employees |> Enum.map(& &1.time_worked) |> Enum.sum()

      total_employee_cost =
        if project.budget_kind == :amount do
          employees
          |> Enum.map(& &1.cost)
          |> Enum.reject(&is_nil/1)
          |> Enum.reduce(Decimal.new(0), &Decimal.add/2)
        end

      invoices =
        if project.budget_kind == :amount,
          do: tagged_cost_invoice_rows(project, period, scope),
          else: []

      total_invoice_cost =
        invoices
        |> Enum.map(& &1.share)
        |> Enum.reduce(Decimal.new(0), &Decimal.add/2)

      %{
        kind: project.budget_kind,
        period: period,
        usage: compute_usage(project, reference_date, scope),
        employees: employees,
        invoices: invoices,
        total_time_worked: total_time_worked,
        total_employee_cost: total_employee_cost,
        total_invoice_cost: total_invoice_cost
      }
    else
      _ -> nil
    end
  end

  @doc """
  Recomputes the `used` value from a `spending_breakdown/3` result.

  For hours budgets this is logged time in hours; for amount budgets it is the
  sum of employee salary cost and tagged cost-invoice shares.
  """
  @spec spending_components_used(spending_breakdown()) :: Decimal.t()
  def spending_components_used(%{kind: :hours, total_time_worked: seconds}) do
    seconds_to_hours(seconds)
  end

  def spending_components_used(%{kind: :amount} = breakdown) do
    employee_cost = breakdown.total_employee_cost || Decimal.new(0)
    Decimal.add(employee_cost, breakdown.total_invoice_cost)
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
    tagged_cost_invoice_rows(%Project{tag_definition_id: tag_definition_id}, period, scope)
    |> Enum.map(& &1.share)
    |> Enum.reduce(Decimal.new(0), &Decimal.add/2)
  end

  defp tagged_cost_invoice_rows(%Project{tag_definition_id: nil}, _period, _scope), do: []

  defp tagged_cost_invoice_rows(%Project{tag_definition_id: tag_definition_id}, period, scope) do
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
    |> Enum.map(fn invoice ->
      share = project_invoice_share(invoice, key)

      if Decimal.compare(share, 0) == :gt do
        %{
          id: invoice.id,
          seller_display_name: invoice.seller_display_name,
          issue_date: invoice.issue_date,
          share: share
        }
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(& &1.issue_date, {:desc, Date})
  end

  defp employee_rows(project, sessions, period, scope) do
    time_by_user =
      sessions
      |> Enum.group_by(& &1.member.user_id)
      |> Map.new(fn {uid, ss} -> {uid, ss |> Enum.map(& &1.duration) |> Enum.sum()} end)

    member_ids = MapSet.new(project.members, & &1.user_id)
    session_user_ids = MapSet.new(Map.keys(time_by_user))
    all_user_ids = MapSet.union(member_ids, session_user_ids)

    users_by_id = Map.new(project.members, &{&1.user_id, %{&1.user | member: &1}})

    display_salaries =
      Payroll.list_salaries!(%{active_at: Date.end_of_month(period.ends_on)},
        scope: scope,
        load: [:member]
      )

    display_rate_by_user = Map.new(display_salaries, &{&1.member.user_id, &1.hourly_rate})

    all_user_ids
    |> Enum.map(fn uid ->
      user = resolve_user(uid, users_by_id, scope)
      time = Map.get(time_by_user, uid, 0)

      cost =
        if time == 0 do
          nil
        else
          user_sessions = Enum.filter(sessions, &(&1.member.user_id == uid))
          employee_salary_cost(user_sessions, scope)
        end

      %{
        id: user.id,
        user: user,
        time_worked: time,
        hourly_rate: Map.get(display_rate_by_user, uid),
        cost: cost,
        removed_from_project: not MapSet.member?(member_ids, uid)
      }
    end)
    |> Enum.sort_by(&{&1.removed_from_project, &1.user.member.name, &1.user.email})
  end

  defp employee_salary_cost(user_sessions, scope) do
    user_sessions
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

  defp resolve_user(uid, users_by_id, scope) do
    case Map.get(users_by_id, uid) do
      nil -> Core.get_org_user!(%{id: uid}, scope: scope, load: [:member])
      u -> u
    end
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
      Decimal.compare(percent, @exceeded_threshold) != :lt -> :exceeded
      Decimal.compare(percent, @warning_threshold) != :lt -> :warning
      true -> :ok
    end
  end
end
