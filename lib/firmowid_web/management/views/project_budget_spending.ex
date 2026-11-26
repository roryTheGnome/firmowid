defmodule FirmowidWeb.Management.Views.ProjectBudgetSpending do
  @moduledoc false
  use FirmowidWeb, :live_view

  on_mount {FirmowidWeb.Infrastructure.Hooks.RequireAdmin, :default}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, gettext("Budget spending"))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div />
    """
  end
end