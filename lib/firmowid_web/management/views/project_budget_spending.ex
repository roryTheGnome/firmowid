defmodule FirmowidWeb.Management.Views.ProjectBudgetSpending do
  @moduledoc false
  use FirmowidWeb, :live_view

  import FirmowidUI.Components.Button
  import FirmowidUI.Components.Link
  import FirmowidWeb.DesignSystem.Components.CoreComponents
  import FirmowidWeb.DesignSystem.Components.MonthPicker
  import Phoenix.Component, except: [link: 1]

  alias Firmowid.TimeFormatter
  alias Firmowid.Timetracker
  alias Firmowid.Timetracker.Project
  alias Firmowid.Timetracker.ProjectBudget
  alias FirmowidWeb.Invoicing.Utilities.Navigation, as: InvoicingNavigation
  alias FirmowidWeb.Management.Utilities.CounterpartyHelpers
  alias FirmowidWeb.Management.Utilities.Navigation
  alias FirmowidWeb.Management.Views.Project, as: ProjectView

  on_mount {FirmowidWeb.Infrastructure.Hooks.RequireAdmin, :default}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl true
  def handle_params(%{"id" => project_id} = params, _url, socket) do
    scope = socket.assigns.ash_scope
    params = Navigation.project_params(params)
    selected_date = Navigation.parse_month(params)

    project = Project.get!(project_id, scope: scope, load: [:counterparty])
    active_months = Timetracker.months_with_sessions(%{project_id: project_id}, scope)

    case ProjectBudget.spending_breakdown(project, selected_date, scope) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("This project has no budget."))
         |> push_navigate(to: Navigation.project_path(project.id, %{miesiac: selected_date}))}

      breakdown ->
        employees = enrich_employees(breakdown.employees, scope)

        socket =
          socket
          |> assign(:project, project)
          |> assign(:selected_date, selected_date)
          |> assign(:active_months, active_months)
          |> assign(:breakdown, breakdown)
          |> assign(:employees, employees)
          |> assign(:page_title, gettext("%{project} — budget spending", project: project.name))

        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("change-month", %{"month" => month}, %{assigns: %{project: project}} = socket) do
    {:noreply,
     push_patch(socket,
       to: Navigation.project_budget_spending_path(project.id, %{miesiac: month})
     )}
  end

  def handle_event("toggle-user", %{"id" => user_id}, socket) do
    scope = socket.assigns.ash_scope
    project = socket.assigns.project
    period = socket.assigns.breakdown.period

    employees =
      Enum.map(socket.assigns.employees, fn
        %{id: ^user_id} = employee ->
          employee
          |> Map.put(:expanded, !employee.expanded)
          |> Map.put_new_lazy(:sessions_with_duration, fn ->
            session_filters(project, employee.user.member.id, period, socket.assigns.selected_date)
            |> Timetracker.list_sessions!(scope: scope, load: :duration)
            |> group_sessions_by_title()
          end)

        employee ->
          employee
      end)

    {:noreply, assign(socket, :employees, employees)}
  end

  @impl true
  def handle_info(:inbox_refresh, socket) do
    {:noreply, reload_breakdown(socket)}
  end

  @doc false
  def amount_budget?(%{kind: :amount}), do: true
  def amount_budget?(_), do: false

  @doc false
  def monthly_budget?(%{period: %{scope: :monthly}}), do: true
  def monthly_budget?(_), do: false

  @doc false
  def budget_back_params(%{period: %{scope: :monthly}}, selected_date) do
    %{miesiac: selected_date}
  end

  def budget_back_params(_breakdown, _selected_date), do: %{}

  defp reload_breakdown(socket) do
    %{project: project, selected_date: selected_date, ash_scope: scope} = socket.assigns

    case ProjectBudget.spending_breakdown(project, selected_date, scope) do
      nil ->
        socket

      breakdown ->
        employees = preserve_expanded(socket.assigns.employees, enrich_employees(breakdown.employees, scope))

        socket
        |> assign(:breakdown, breakdown)
        |> assign(:employees, employees)
    end
  end

  defp preserve_expanded(previous, current) do
    expanded_by_id = Map.new(previous, &{&1.id, &1.expanded})

    Enum.map(current, fn employee ->
      expanded = Map.get(expanded_by_id, employee.id, false)
      Map.put(employee, :expanded, expanded)
    end)
  end

  defp enrich_employees(employees, scope) do
    Enum.map(employees, fn employee ->
      user =
        Ash.load!(employee.user, [member: [avatar_blob: [:url]]], scope: scope)

      employee
      |> Map.put(:user, user)
      |> Map.put(:expanded, false)
    end)
  end

  defp session_filters(project, member_id, %{scope: :monthly}, selected_date) do
    %{
      member_id: member_id,
      project_id: project.id,
      month: selected_date.month,
      year: selected_date.year
    }
  end

  defp session_filters(project, member_id, period, _selected_date) do
    %{
      project_id: project.id,
      member_id: member_id,
      started_from: period_start_datetime(period),
      started_to: period_end_datetime(period)
    }
  end

  defp period_start_datetime(%{starts_on: starts_on}) do
    DateTime.new!(starts_on, ~T[00:00:00.000000], "Etc/UTC")
  end

  defp period_end_datetime(%{ends_on: ends_on}) do
    ends_on |> Date.add(1) |> DateTime.new!(~T[00:00:00.000000], "Etc/UTC")
  end

  defp group_sessions_by_title(sessions) do
    sessions
    |> Enum.group_by(& &1.title)
    |> Enum.map(fn {title, ss} ->
      %{title: title, duration: ss |> Enum.map(& &1.duration) |> Enum.sum()}
    end)
    |> Enum.sort_by(& &1.duration, :desc)
  end
end