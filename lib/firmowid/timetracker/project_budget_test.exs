defmodule Firmowid.Timetracker.ProjectBudgetTest do
  @moduledoc false
  use Firmowid.DataCase, async: true

  import Firmowid.AccountsFixtures
  import Firmowid.TimetrackerFixtures

  alias Firmowid.Scope
  alias Firmowid.Timetracker.Project
  alias Firmowid.Timetracker.ProjectBudget

  describe "usage/3" do
    test "reports :ok below the warning threshold" do
      admin = admin_fixture()
      scope = scope(admin)
      project = budget_project!(admin, %{budget_limit: Decimal.new("10")})

      log_hours!(admin, project, ~U[2026-11-05 09:00:00Z], ~U[2026-11-05 10:00:00Z])

      assert %{status: :ok, used: used} = ProjectBudget.usage(project, ~D[2026-11-15], scope)
      assert Decimal.equal?(used, Decimal.new("1"))
    end

    test "reports :warning from 95% of the limit" do
      admin = admin_fixture()
      scope = scope(admin)
      project = budget_project!(admin, %{budget_limit: Decimal.new("10")})

      log_hours!(admin, project, ~U[2026-11-05 09:00:00Z], ~U[2026-11-05 18:30:00Z])

      assert %{status: :warning, percent: percent} =
               ProjectBudget.usage(project, ~D[2026-11-15], scope)

      assert Decimal.equal?(percent, Decimal.new("95.0"))
    end

    test "reports :exceeded above 100% of the limit" do
      admin = admin_fixture()
      scope = scope(admin)
      project = budget_project!(admin, %{budget_limit: Decimal.new("10")})

      log_hours!(admin, project, ~U[2026-11-05 09:00:00Z], ~U[2026-11-05 19:01:00Z])

      assert %{status: :exceeded, percent: percent} =
               ProjectBudget.usage(project, ~D[2026-11-15], scope)

      assert Decimal.compare(percent, Decimal.new("100")) == :gt
    end

    test "counts only sessions inside an engagement period" do
      admin = admin_fixture()
      scope = scope(admin)

      project =
        budget_project!(admin, %{
          budget_scope: :engagement,
          budget_engagement_starts_on: ~D[2026-11-01],
          budget_engagement_ends_on: ~D[2026-11-15],
          budget_limit: Decimal.new("10")
        })

      log_hours!(admin, project, ~U[2026-10-31 09:00:00Z], ~U[2026-10-31 10:00:00Z])
      log_hours!(admin, project, ~U[2026-11-05 09:00:00Z], ~U[2026-11-05 10:00:00Z])

      assert %{used: used, period: %{scope: :engagement}} =
               ProjectBudget.usage(project, ~D[2026-11-20], scope)

      assert Decimal.equal?(used, Decimal.new("1"))
    end

    test "adds salary cost for amount budgets" do
      admin = admin_fixture()
      scope = scope(admin)

      project =
        budget_project!(admin, %{budget_kind: :amount, budget_limit: Decimal.new("1000")})

      user_salary_fixture(%{
        user_id: admin.id,
        organization_id: admin.member.organization_id,
        hourly_rate: Decimal.new("100")
      })

      log_hours!(admin, project, ~U[2026-11-05 09:00:00Z], ~U[2026-11-05 14:00:00Z])

      assert %{kind: :amount, used: used, status: :ok} =
               ProjectBudget.usage(project, ~D[2026-11-15], scope)

      assert Decimal.equal?(used, Decimal.new("500"))
    end

    test "returns nil when the project has no budget" do
      admin = admin_fixture()
      scope = scope(admin)
      project = project_fixture(%{organization_id: admin.member.organization_id})

      assert is_nil(ProjectBudget.usage(project, ~D[2026-11-15], scope))
    end

    test "returns nil for non-admin actors" do
      admin = admin_fixture()
      org_id = admin.member.organization_id
      employee = user_in_org_fixture(org_id)
      project = budget_project!(admin, %{budget_limit: Decimal.new("10")})

      log_hours!(admin, project, ~U[2026-11-05 09:00:00Z], ~U[2026-11-05 10:00:00Z])

      employee_scope = Scope.new!(employee, org_id)

      assert is_nil(ProjectBudget.usage(project, ~D[2026-11-15], employee_scope))
    end
  end

  describe "usage_by_project/3" do
    test "returns usage keyed by project id for admins only" do
      admin = admin_fixture()
      scope = scope(admin)
      project = budget_project!(admin, %{budget_limit: Decimal.new("10")})
      other = project_fixture(%{organization_id: admin.member.organization_id})

      log_hours!(admin, project, ~U[2026-11-05 09:00:00Z], ~U[2026-11-05 10:00:00Z])

      usage_by_project =
        ProjectBudget.usage_by_project([project, other], ~D[2026-11-15], scope)

      assert %{used: used} = Map.fetch!(usage_by_project, project.id)
      assert Decimal.equal?(used, Decimal.new("1"))
      refute Map.has_key?(usage_by_project, other.id)
    end

    test "returns an empty map for non-admin actors" do
      admin = admin_fixture()
      org_id = admin.member.organization_id
      employee = user_in_org_fixture(org_id)
      project = budget_project!(admin, %{budget_limit: Decimal.new("10")})

      assert ProjectBudget.usage_by_project(
               [project],
               ~D[2026-11-15],
               Scope.new!(employee, org_id)
             ) ==
               %{}
    end
  end

  defp scope(admin), do: Scope.new!(admin, admin.member.organization_id)

  defp budget_project!(admin, attrs) do
    org_id = admin.member.organization_id
    project = project_fixture(%{organization_id: org_id})

    budget_attrs =
      attrs
      |> Map.put_new(:budget_kind, :hours)
      |> Map.put_new(:budget_scope, :monthly)
      |> Map.put_new(:budget_limit, Decimal.new("10"))

    {:ok, project} = Project.update(project, budget_attrs, scope: scope(admin))
    project
  end

  defp log_hours!(admin, project, start_datetime, end_datetime) do
    session_fixture(%{
      organization_id: admin.member.organization_id,
      project_id: project.id,
      user_id: admin.id,
      start_datetime: start_datetime,
      end_datetime: end_datetime
    })
  end
end
