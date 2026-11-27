defmodule FirmowidWeb.Inbox.Utilities.QueueTest do
  @moduledoc false
  use Firmowid.DataCase, async: true

  import Firmowid.AccountsFixtures
  import Firmowid.InvoicingFixtures
  import Firmowid.TimetrackerFixtures

  alias Firmowid.Core
  alias Firmowid.Scope
  alias Firmowid.Timetracker.Project
  alias FirmowidWeb.Inbox.Utilities.Queue

  test "the month shows the income of the whole month, like the analysis" do
    admin = admin_fixture()
    scope = Scope.new!(admin, admin.member.organization_id)

    seed_sales_invoice!(
      %{
        invoice_number: "FV/1/11/2026",
        buyer_full_name: "Buyer",
        buyer_display_name: "Buyer",
        seller_display_name: "Our Company",
        sale_date: ~D[2026-11-20],
        issue_date: ~D[2026-11-20],
        due_date: ~D[2026-11-20],
        payment_method: :transfer,
        currency: "PLN",
        buyer_type: :company,
        skip_invoicing: true,
        sales_invoice_items: [
          %{name: "Service", quantity: 1, unit: "pcs", unit_price: Decimal.new("1000.00")}
        ]
      },
      scope: scope
    )

    analysis_month =
      Firmowid.Analysis.get_organization_totals(~D[2026-11-01], ~D[2026-11-30], [], scope)

    assert [%{side: :sales, value: income}, %{side: :cost}] = Queue.month(scope, ~D[2026-11-10])
    refute Decimal.equal?(analysis_month.total_income, 0)

    assert income ==
             Money.to_string!(Money.new(:PLN, analysis_month.total_income),
               fractional_digits: 0,
               minimum_grouping_digits: 1
             )
  end

  describe "project budget items" do
    test "shows warning and exceeded projects for admins" do
      admin = admin_fixture()
      org_id = admin.member.organization_id
      scope = Scope.new!(admin, org_id)
      organization = Core.get_organization!(org_id, scope: scope)
      today = Firmowid.LocalDate.today()

      near_limit =
        project_with_budget!(admin, %{name: "Near Limit", budget_limit: Decimal.new("2")})

      over_limit =
        project_with_budget!(admin, %{name: "Over Limit", budget_limit: Decimal.new("2")})

      within_limit =
        project_with_budget!(admin, %{name: "Within Limit", budget_limit: Decimal.new("10")})

      # 1.9 h of 2 h → warning (95%).
      log_session!(admin, near_limit, datetime_on(today, ~T[08:00:00]), 6840)
      # 2 h 1 min of 2 h → exceeded.
      log_session!(admin, over_limit, datetime_on(today, ~T[12:00:00]), 7260)
      log_session!(admin, within_limit, datetime_on(today, ~T[16:00:00]), 3600)

      inbox_ids = scope |> Queue.attention_items(organization) |> Enum.map(& &1.id)
      period_key = period_key(today)

      assert "project-budget-#{near_limit.id}-#{period_key}-warning" in inbox_ids
      assert "project-budget-#{over_limit.id}-#{period_key}-exceeded" in inbox_ids
      refute Enum.any?(inbox_ids, &String.starts_with?(&1, "project-budget-#{within_limit.id}-"))
    end

    test "omits project budget items for non-admins" do
      admin = admin_fixture()
      org_id = admin.member.organization_id
      accountant = user_in_org_fixture(org_id, %{role: :accountant})
      scope = Scope.new!(accountant, org_id)
      organization = Core.get_organization!(org_id, scope: scope)
      today = Firmowid.LocalDate.today()

      project = project_with_budget!(admin, %{name: "Over Limit", budget_limit: Decimal.new("2")})
      log_session!(admin, project, datetime_on(today, ~T[10:00:00]), 7260)

      inbox_ids = scope |> Queue.attention_items(organization) |> Enum.map(& &1.id)

      refute Enum.any?(inbox_ids, &String.starts_with?(&1, "project-budget-"))
    end
  end

  defp project_with_budget!(admin, attrs) do
    scope = Scope.new!(admin, admin.member.organization_id)
    org_id = admin.member.organization_id

    project =
      project_fixture(%{
        organization_id: org_id,
        name: Map.fetch!(attrs, :name)
      })

    budget_attrs =
      attrs
      |> Map.delete(:name)
      |> Map.put_new(:budget_kind, :hours)
      |> Map.put_new(:budget_scope, :monthly)

    {:ok, project} = Project.update(project, budget_attrs, scope: scope)
    project
  end

  defp log_session!(admin, project, start_datetime, duration_seconds) do
    end_datetime = DateTime.shift(start_datetime, second: duration_seconds)

    session_fixture(%{
      organization_id: admin.member.organization_id,
      project_id: project.id,
      user_id: admin.id,
      start_datetime: start_datetime,
      end_datetime: end_datetime
    })
  end

  defp datetime_on(%Date{} = day, time) do
    DateTime.new!(day, time, "Etc/UTC")
  end

  defp period_key(%Date{year: year, month: month}) do
    "#{year}-#{pad(month)}"
  end

  defp pad(value) when value < 10, do: "0#{value}"
  defp pad(value), do: to_string(value)
end
