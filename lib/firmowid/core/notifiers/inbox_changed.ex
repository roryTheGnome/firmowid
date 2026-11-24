defmodule Firmowid.Core.Notifiers.InboxChanged do
  @moduledoc """
  Tells the organization's open pages that something the inbox shows changed:
  a leave request, a timesheet change request, a business trip, a contract, a
  project budget, salary rates, analysis tags on invoices, an invoice, a sales
  invoice the KSeF import skipped, a bank connection, the KSeF connection, a work
  session or an item the company put aside.

  Resources list it in `simple_notifiers`; the kind of change follows from the
  resource. Subscribers get `{:inbox_changed, kind}` after the change commits and reload
  what they show; the message carries no data, so it never leaks a record to
  members who may not see it.
  """

  use Ash.Notifier

  alias Ash.Notifier.Notification

  @type kind :: :attention | :books | :personal | :presence

  @kinds %{
    Firmowid.Timetracker.LeaveRequest => :attention,
    Firmowid.Timetracker.HoursRecord => :attention,
    Firmowid.Timetracker.Project => :attention,
    Firmowid.Delegations.Delegation => :attention,
    Firmowid.Finances.BankAccount => :attention,
    Firmowid.Finances.Requisition => :attention,
    Firmowid.Ksef.Credential => :attention,
    Firmowid.Invoicing.SalesInvoice => :books,
    Firmowid.Invoicing.CostInvoice => [:books, :attention],
    Firmowid.Invoicing.SkippedKsefSalesInvoice => :books,
    Firmowid.Payroll.UserEmploymentContract => :personal,
    Firmowid.Payroll.UserSalary => :attention,
    Firmowid.Analysis.EntityTag => :attention,
    Firmowid.Timetracker.Session => :presence,
    Firmowid.Core.InboxSnooze => :attention
  }

  @doc "Subscribes the calling process to inbox changes of one organization."
  @spec subscribe(Ash.UUID.t()) :: :ok | {:error, term()}
  def subscribe(organization_id), do: Phoenix.PubSub.subscribe(Firmowid.PubSub, topic(organization_id))

  @doc false
  @impl true
  @spec notify(Notification.t()) :: :ok
  def notify(%Notification{resource: resource, data: %{organization_id: organization_id}})
      when is_binary(organization_id) do
    case Map.fetch(@kinds, resource) do
      {:ok, kinds} ->
        for kind <- List.wrap(kinds) do
          Phoenix.PubSub.broadcast(
            Firmowid.PubSub,
            topic(organization_id),
            {:inbox_changed, kind}
          )
        end

        :ok

      :error ->
        :ok
    end
  end

  def notify(_notification), do: :ok

  defp topic(organization_id), do: "inbox:#{organization_id}"
end
