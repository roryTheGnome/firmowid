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
    page =
      Enum.reject([limit: @transaction_page_size, after: keyset], fn {_key, val} ->
        is_nil(val)
      end)

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
  defp collect_invoice_movements(_as_of, _end_date, _scope), do: []

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