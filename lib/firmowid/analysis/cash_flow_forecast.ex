defmodule Firmowid.Analysis.CashFlowForecast do
  @moduledoc """
  Forward-looking cash projection from synced account balances, unpaid invoices,
  payroll payout estimates, and unfulfilled expected transactions.

  This is a **projection** only: it does not mark anything paid, initiate
  payments, or change analysis totals. Out of scope: recurring invoices, transfer
  files, generating expected tax payments, and marking movements as fulfilled.

  Expects an authorized `Scope` with at least the invoicing role, like
  `Firmowid.Analysis.get_organization_totals/4`.

  Starting balance sums every synced transaction per bank account (including
  matched and internal transfers). Only the forward projection uses unpaid
  invoices and estimates.
  """

  alias Firmowid.Analysis
  alias Firmowid.Currencies.Converter, as: Currencies
  alias Firmowid.Finances
  alias Firmowid.Finances.BankAccount
  alias Firmowid.Finances.Transaction
  alias Firmowid.Invoicing
  alias Firmowid.Invoicing.CostInvoice
  alias Firmowid.Invoicing.SalesInvoice
  alias Firmowid.Scope

  @type horizon_days :: 30 | 60 | 90

  @type movement_source ::
          :sales_invoice | :cost_invoice | :payroll | :expected_transaction

  @type movement :: %{
          optional(:member_id) => String.t(),
          optional(:invoice_number) => String.t(),
          source: movement_source(),
          source_id: String.t(),
          date: Date.t(),
          amount: Money.t(),
          amount_pln: Decimal.t(),
          label: String.t()
        }

  @type account_snapshot :: %{
          id: String.t(),
          label: String.t(),
          currency: String.t(),
          balance: Money.t(),
          oldest_booking_date: Date.t() | nil
        }

  @type forecast_day :: %{
          date: Date.t(),
          balance_pln: Decimal.t(),
          movements: [movement()]
        }

  @type forecast :: %{
          projection: true,
          horizon_days: horizon_days(),
          as_of: Date.t(),
          accounts: [account_snapshot()],
          starting_balance_pln: Decimal.t(),
          days: [forecast_day()]
        }

  @doc """
  Builds a cash-flow projection for the next `horizon_days` days.

  The starting PLN balance sums each connected account's synced transactions
  (`accounts` carries per-account balances and the oldest booking date). Movements
  include unpaid confirmed invoices on their due date (past-due clamped to `as_of`),
  current-month payroll estimates, and unfulfilled expected transactions.
  Foreign amounts are converted to PLN with the same rules as analysis totals.

  Raises `ArgumentError` when `horizon_days` is not 30, 60, or 90.
  """
  @spec build(horizon_days(), Scope.t()) :: forecast()
  def build(horizon_days, %Scope{} = scope) when horizon_days in [30, 60, 90] do
    as_of = Date.utc_today()
    end_date = Date.add(as_of, horizon_days)

    accounts = account_snapshots(scope)
    starting = starting_balance_pln(accounts, as_of)

    movements =
      []
      |> Kernel.++(collect_invoice_movements(as_of, end_date, scope))
      |> Kernel.++(collect_payroll_movements(as_of, scope))
      |> Kernel.++(collect_expected_movements(as_of, end_date, scope))

    %{
      projection: true,
      horizon_days: horizon_days,
      as_of: as_of,
      accounts: accounts,
      starting_balance_pln: starting,
      days: build_timeline(as_of, end_date, starting, movements)
    }
  end

  def build(horizon_days, %Scope{}) do
    raise ArgumentError,
          "invalid horizon_days: expected 30, 60, or 90, got #{inspect(horizon_days)}"
  end

  @transaction_page_size 100
  @invoice_page_size 100

  @spec account_snapshots(Scope.t()) :: [account_snapshot()]
  defp account_snapshots(scope) do
    read_scope = Analysis.analysis_scope(scope)

    accounts =
      Finances.list_bank_accounts!(
        query: [sort: [institution_name: :asc, iban: :asc, id: :asc]],
        scope: read_scope
      )

    by_account =
      read_scope
      |> list_all_transactions()
      |> Enum.group_by(& &1.bank_account_id)

    Enum.map(accounts, fn account ->
      transactions = Map.get(by_account, account.id, [])

      %{
        id: account.id,
        label: account_label(account),
        currency: account.currency,
        balance: account_balance(account.currency, transactions),
        oldest_booking_date: oldest_booking_date(transactions)
      }
    end)
  end

  @spec starting_balance_pln([account_snapshot()], Date.t()) :: Decimal.t()
  defp starting_balance_pln([], _as_of), do: Decimal.new(0)

  defp starting_balance_pln(accounts, as_of) do
    accounts
    |> Enum.reduce(Decimal.new(0), fn %{balance: balance, currency: currency}, sum ->
      pln =
        Currencies.normalize_amount_to_pln(Money.to_decimal(balance), currency, as_of)
        |> Decimal.round(2, :half_up)

      Decimal.add(sum, pln)
    end)
    |> Decimal.round(2, :half_up)
  end

  @spec list_all_transactions(Scope.t()) :: [Transaction.t()]
  defp list_all_transactions(read_scope) do
    list_transaction_pages(read_scope, nil, [])
  end

  defp list_transaction_pages(read_scope, keyset, acc) do
    page = keyset_page(@transaction_page_size, keyset)

    case Finances.list_transactions!(
           %{},
           query: [select: [:bank_account_id, :amount, :booking_date, :id], sort: [id: :asc]],
           page: page,
           scope: read_scope
         ) do
      %Ash.Page.Keyset{results: results, after: next, more?: true} when not is_nil(next) ->
        list_transaction_pages(read_scope, next, acc ++ results)

      %Ash.Page.Keyset{results: results} ->
        acc ++ results

      results when is_list(results) ->
        acc ++ results
    end
  end

  @spec account_balance(String.t(), [Transaction.t()]) :: Money.t()
  defp account_balance(currency, transactions) do
    Enum.reduce(transactions, Money.new!(currency, 0), fn transaction, balance ->
      Money.add!(balance, transaction.amount)
    end)
  end

  @spec account_label(BankAccount.t()) :: String.t()
  defp account_label(%BankAccount{name: name}) when is_binary(name) and name != "" do
    String.trim(name)
  end

  defp account_label(%BankAccount{institution_name: name}) when is_binary(name) and name != "" do
    String.trim(name)
  end

  defp account_label(%BankAccount{iban: iban}) when is_binary(iban), do: iban

  @spec oldest_booking_date([Transaction.t()]) :: Date.t() | nil
  defp oldest_booking_date([]), do: nil

  defp oldest_booking_date(transactions) do
    transactions
    |> Enum.map(& &1.booking_date)
    |> Enum.min(Date, fn -> nil end)
  end

  @spec collect_invoice_movements(Date.t(), Date.t(), Scope.t()) :: [movement()]
  defp collect_invoice_movements(as_of, end_date, scope) do
    read_scope = Analysis.analysis_scope(scope)

    collect_sales_inflow_movements(as_of, end_date, read_scope) ++
      collect_cost_refund_movements(as_of, end_date, read_scope) ++
      collect_cost_outflow_movements(as_of, end_date, read_scope)
  end

  @spec collect_sales_inflow_movements(Date.t(), Date.t(), Scope.t()) :: [movement()]
  defp collect_sales_inflow_movements(as_of, end_date, read_scope) do
    read_scope
    |> unpaid_sales_invoices()
    |> Enum.flat_map(&sales_inflow_movement(&1, as_of, end_date))
  end

  @spec collect_cost_refund_movements(Date.t(), Date.t(), Scope.t()) :: [movement()]
  defp collect_cost_refund_movements(as_of, end_date, read_scope) do
    read_scope
    |> unpaid_cost_invoices()
    |> Enum.filter(&Money.positive?(&1.effective_amount))
    |> Enum.flat_map(&cost_refund_movement(&1, as_of, end_date))
  end

  @spec collect_cost_outflow_movements(Date.t(), Date.t(), Scope.t()) :: [movement()]
  defp collect_cost_outflow_movements(as_of, end_date, read_scope) do
    read_scope
    |> unpaid_cost_invoices()
    |> Enum.filter(&Money.negative?(&1.effective_amount))
    |> Enum.flat_map(&cost_outflow_movement(&1, as_of, end_date))
  end

  @spec unpaid_sales_invoices(Scope.t()) :: [SalesInvoice.t()]
  defp unpaid_sales_invoices(read_scope) do
    list_all_sales_invoices(
      read_scope,
      %{reconciliation: :pending, merge_corrections: true, submission: :confirmed}
    )
  end

  @spec unpaid_cost_invoices(Scope.t()) :: [CostInvoice.t()]
  defp unpaid_cost_invoices(read_scope) do
    list_all_cost_invoices(read_scope, %{reconciliation: :pending, merge_corrections: true})
  end

  defp list_all_sales_invoices(read_scope, args) do
    sales_invoice_pages(read_scope, args, nil, [])
  end

  defp sales_invoice_pages(read_scope, args, keyset, acc) do
    page = keyset_page(@invoice_page_size, keyset)

    case Invoicing.list_sales_invoices!(args,
           load: [:effective_amount, :effective_due_date, :buyer_display_name_label],
           query: [sort: [id: :asc]],
           page: page,
           scope: read_scope
         ) do
      %Ash.Page.Keyset{results: results, after: next, more?: true} when not is_nil(next) ->
        sales_invoice_pages(read_scope, args, next, acc ++ results)

      %Ash.Page.Keyset{results: results} ->
        acc ++ results

      results when is_list(results) ->
        acc ++ results
    end
  end

  defp list_all_cost_invoices(read_scope, args) do
    cost_invoice_pages(read_scope, args, nil, [])
  end

  defp cost_invoice_pages(read_scope, args, keyset, acc) do
    page = keyset_page(@invoice_page_size, keyset)

    case Invoicing.list_cost_invoices!(args,
           load: [:effective_amount, :effective_due_date, :effective_seller_display_name],
           query: [sort: [id: :asc]],
           page: page,
           scope: read_scope
         ) do
      %Ash.Page.Keyset{results: results, after: next, more?: true} when not is_nil(next) ->
        cost_invoice_pages(read_scope, args, next, acc ++ results)

      %Ash.Page.Keyset{results: results} ->
        acc ++ results

      results when is_list(results) ->
        acc ++ results
    end
  end

  defp keyset_page(size, nil), do: [limit: size]
  defp keyset_page(size, keyset), do: [limit: size, after: keyset]

  defp sales_inflow_movement(%SalesInvoice{} = invoice, as_of, end_date) do
    with %Date{} = due <- invoice.effective_due_date,
         %Money{} = amount <- inflow_money(invoice.effective_amount),
         scheduled = clamp_scheduled_date(due, as_of),
         true <- in_forecast_window?(scheduled, as_of, end_date) do
      [inflow_movement(:sales_invoice, invoice.id, scheduled, amount, invoice.sale_date, movement_label(invoice), invoice.invoice_number)]
    else
      _ -> []
    end
  end

  defp cost_refund_movement(%CostInvoice{} = invoice, as_of, end_date) do
    with %Date{} = due <- invoice.effective_due_date,
         %Money{} = amount <- inflow_money(invoice.effective_amount),
         scheduled = clamp_scheduled_date(due, as_of),
         true <- in_forecast_window?(scheduled, as_of, end_date) do
      [inflow_movement(:cost_invoice, invoice.id, scheduled, amount, invoice.sale_date, movement_label(invoice), nil)]
    else
      _ -> []
    end
  end

  defp cost_outflow_movement(%CostInvoice{} = invoice, as_of, end_date) do
    with %Date{} = due <- invoice.effective_due_date,
         %Money{} = amount <- outflow_money(invoice.effective_amount),
         scheduled = clamp_scheduled_date(due, as_of),
         true <- in_forecast_window?(scheduled, as_of, end_date) do
      [outflow_movement(:cost_invoice, invoice.id, scheduled, amount, invoice.sale_date, movement_label(invoice))]
    else
      _ -> []
    end
  end

  defp movement_label(%SalesInvoice{buyer_display_name_label: label}) when is_binary(label), do: String.trim(label)
  defp movement_label(%SalesInvoice{}), do: ""
  defp movement_label(%CostInvoice{effective_seller_display_name: label}) when is_binary(label), do: String.trim(label)
  defp movement_label(%CostInvoice{}), do: ""

  defp inflow_movement(source, source_id, date, %Money{} = amount, sale_date, label, invoice_number) do
    movement_fields(source, source_id, date, amount, sale_date, label)
    |> Map.put(:amount_pln, inflow_amount_pln(amount, sale_date))
    |> maybe_put_invoice_number(invoice_number)
  end

  defp outflow_movement(source, source_id, date, %Money{} = amount, sale_date, label) do
    Map.put(movement_fields(source, source_id, date, amount, sale_date, label), :amount_pln, outflow_amount_pln(amount, sale_date))
  end

  defp movement_fields(source, source_id, date, %Money{} = amount, _sale_date, label) do
    %{source: source, source_id: source_id, date: date, amount: amount, label: label}
  end

  defp maybe_put_invoice_number(movement, number) when is_binary(number) and number != "" do
    Map.put(movement, :invoice_number, number)
  end

  defp maybe_put_invoice_number(movement, _), do: movement

  defp inflow_money(%Money{} = amount) do
    if Money.positive?(amount), do: Money.abs(amount), else: nil
  end

  defp outflow_money(%Money{} = amount) do
    if Money.negative?(amount), do: amount, else: nil
  end

  defp inflow_amount_pln(%Money{} = amount, %Date{} = sale_date) do
    rate_date = Enum.min([sale_date, Date.utc_today()], Date)

    amount
    |> Money.to_currency_code()
    |> Atom.to_string()
    |> then(&Currencies.normalize_amount_to_pln(Money.to_decimal(amount), &1, rate_date))
    |> Decimal.round(2, :half_up)
  end

  defp inflow_amount_pln(%Money{} = amount, _sale_date) do
    inflow_amount_pln(amount, Date.utc_today())
  end

  defp outflow_amount_pln(%Money{} = amount, sale_date) do
    amount
    |> Money.abs()
    |> then(&inflow_amount_pln(&1, sale_date))
    |> Decimal.negate()
  end

  defp clamp_scheduled_date(due, as_of) do
    if Date.compare(due, as_of) == :lt, do: as_of, else: due
  end

  defp in_forecast_window?(date, as_of, end_date) do
    Date.compare(date, as_of) != :lt and Date.compare(date, end_date) != :gt
  end

  @spec collect_payroll_movements(Date.t(), Scope.t()) :: [movement()]
  defp collect_payroll_movements(_as_of, _scope), do: []

  @spec collect_expected_movements(Date.t(), Date.t(), Scope.t()) :: [movement()]
  defp collect_expected_movements(_as_of, _end_date, _scope), do: []

  @spec build_timeline(Date.t(), Date.t(), Decimal.t(), [movement()]) :: [forecast_day()]
  defp build_timeline(as_of, end_date, starting_balance_pln, movements) do
    by_date =
      movements
      |> sort_movements()
      |> Enum.group_by(& &1.date)

    as_of
    |> Date.range(end_date)
    |> Enum.map_reduce(starting_balance_pln, fn date, balance ->
      day_movements = Map.get(by_date, date, [])

      balance =
        day_movements
        |> Enum.reduce(balance, &Decimal.add(&2, &1.amount_pln))
        |> Decimal.round(2, :half_up)

      {%{date: date, balance_pln: balance, movements: day_movements}, balance}
    end)
    |> elem(0)
  end

  defp sort_movements(movements) do
    Enum.sort_by(movements, fn movement ->
      sign_order =
        case Decimal.compare(movement.amount_pln, 0) do
          :gt -> 0
          _ -> 1
        end

      {movement.date, sign_order, movement.source_id}
    end)
  end
end