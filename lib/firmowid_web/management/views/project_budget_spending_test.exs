defmodule FirmowidWeb.Management.Views.ProjectBudgetSpendingTest do
  @moduledoc false
  use FirmowidWeb.ConnCase, async: true
  use Gettext, backend: Firmowid.Gettext

  import Firmowid.AccountsFixtures
  import Firmowid.TimetrackerFixtures
  import Phoenix.LiveViewTest

  alias Firmowid.Scope
  alias Firmowid.Timetracker.Project
  alias FirmowidWeb.Management.Utilities.Navigation

  test "redirects when the project has no budget", %{conn: conn} do
    admin = admin_fixture()
    project = project_fixture(%{organization_id: admin.member.organization_id})
    conn = log_in_user(conn, admin)

    assert {:error, {:live_redirect, %{to: to}}} =
             live(conn, ~p"/zarzadzanie/projekty/#{project.id}/wykorzystanie-budzetu")

    assert to == Navigation.project_path(project.id, %{miesiac: Date.utc_today() |> Date.beginning_of_month()})
  end

  test "renders budget spending for a configured monthly hours budget", %{conn: conn} do
    admin = admin_fixture()
    scope = current_scope(admin)

    {:ok, project} =
      Project.create(
        %{
          name: unique_project_name(),
          budget_kind: :hours,
          budget_scope: :monthly,
          budget_limit: Decimal.new("100")
        },
        scope: scope
      )

    conn = log_in_user(conn, admin)

    assert {:ok, _view, html} =
             live(
               conn,
               Navigation.project_budget_spending_path(project.id, %{miesiac: Date.utc_today()})
             )

    assert html =~ gettext("Budget spending")
    assert html =~ gettext("Employees")
  end

  test "project page links to budget spending when a budget is configured", %{conn: conn} do
    admin = admin_fixture()
    scope = current_scope(admin)

    {:ok, project} =
      Project.create(
        %{
          name: unique_project_name(),
          budget_kind: :hours,
          budget_scope: :monthly,
          budget_limit: Decimal.new("100")
        },
        scope: scope
      )

    conn = log_in_user(conn, admin)

    assert {:ok, _view, html} = live(conn, ~p"/zarzadzanie/projekty/#{project.id}")

    assert html =~ gettext("View budget spending")
    assert html =~ Navigation.project_budget_spending_path(project.id, %{miesiac: Date.utc_today()})
  end

  defp current_scope(admin) do
    %Scope{actor: admin, tenant: admin.member.organization_id}
  end
end