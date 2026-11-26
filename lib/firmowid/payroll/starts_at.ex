defmodule Firmowid.Payroll.StartsAt do
  @moduledoc """
  Parses and normalizes salary `starts_at` values from forms and API input.

  Rates are stored at UTC midnight of the chosen calendar day.
  """

  @spec parse(term()) :: DateTime.t()
  def parse(nil), do: utc_midnight(Date.utc_today())

  def parse(%Date{} = date), do: utc_midnight(date)

  def parse(%DateTime{} = datetime), do: utc_midnight(datetime)

  def parse(value) when is_binary(value) do
    case Date.from_iso8601(String.trim(value)) do
      {:ok, date} -> utc_midnight(date)
      :error -> utc_midnight(Date.utc_today())
    end
  end

  @spec utc_midnight(Date.t() | DateTime.t()) :: DateTime.t()
  def utc_midnight(%Date{} = date), do: DateTime.new!(date, ~T[00:00:00], "Etc/UTC")

  def utc_midnight(%DateTime{} = datetime), do: utc_midnight(DateTime.to_date(datetime))
end