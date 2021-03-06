defmodule Time do
  @moduledoc """
  A Time struct and functions.

  The Time struct contains the fields hour, minute, second and microseconds.
  New times can be built with the `new/4` function or using the `~T`
  sigil:

      iex> ~T[23:00:07.001]
      ~T[23:00:07.001]

  Both `new/4` and sigil return a struct where the time fields can
  be accessed directly:

      iex> time = ~T[23:00:07.001]
      iex> time.hour
      23
      iex> time.microsecond
      {1000, 3}

  The functions on this module work with the `Time` struct as well
  as any struct that contains the same fields as the `Time` struct,
  such as `NaiveDateTime` and `DateTime`. Such functions expect
  `t:Calendar.time/0` in their typespecs (instead of `t:t/0`).

  Developers should avoid creating the Time structs directly
  and instead rely on the functions provided by this module as well
  as the ones in 3rd party calendar libraries.

  ## Comparing times

  Comparisons in Elixir using `==`, `>`, `<` and similar are structural
  and based on the `Time` struct fields. For proper comparison between
  times, use the `compare/2` function.
  """

  @enforce_keys [:hour, :minute, :second]
  defstruct [:hour, :minute, :second, microsecond: {0, 0}, calendar: Calendar.ISO]

  @type t :: %Time{
          hour: Calendar.hour(),
          minute: Calendar.minute(),
          second: Calendar.second(),
          microsecond: Calendar.microsecond(),
          calendar: Calendar.calendar()
        }

  @doc """
  Returns the current time in UTC.

  ## Examples

      iex> time = Time.utc_now()
      iex> time.hour >= 0
      true

  """
  @spec utc_now(Calendar.calendar()) :: t
  def utc_now(calendar \\ Calendar.ISO) do
    {:ok, _, time, microsecond} = Calendar.ISO.from_unix(:os.system_time(), :native)
    {hour, minute, second} = time

    iso_time = %Time{
      hour: hour,
      minute: minute,
      second: second,
      microsecond: microsecond,
      calendar: Calendar.ISO
    }

    convert!(iso_time, calendar)
  end

  @doc """
  Builds a new time.

  Expects all values to be integers. Returns `{:ok, time}` if each
  entry fits its appropriate range, returns `{:error, reason}` otherwise.

  Note a time may have 60 seconds in case of leap seconds. Microseconds
  can also be given with a precision, which must be an integer between
  0 and 6.

  ## Examples

      iex> Time.new(0, 0, 0, 0)
      {:ok, ~T[00:00:00.000000]}
      iex> Time.new(23, 59, 59, 999_999)
      {:ok, ~T[23:59:59.999999]}
      iex> Time.new(23, 59, 60, 999_999)
      {:ok, ~T[23:59:60.999999]}

      # Time with microseconds and their precision
      iex> Time.new(23, 59, 60, {10_000, 2})
      {:ok, ~T[23:59:60.01]}

      iex> Time.new(24, 59, 59, 999_999)
      {:error, :invalid_time}
      iex> Time.new(23, 60, 59, 999_999)
      {:error, :invalid_time}
      iex> Time.new(23, 59, 61, 999_999)
      {:error, :invalid_time}
      iex> Time.new(23, 59, 59, 1_000_000)
      {:error, :invalid_time}

      # Invalid precision
      Time.new(23, 59, 59, {999_999, 10})
      {:error, :invalid_time}

  """
  @spec new(
          Calendar.hour(),
          Calendar.minute(),
          Calendar.second(),
          Calendar.microsecond() | integer,
          Calendar.calendar()
        ) :: {:ok, t} | {:error, atom}
  def new(hour, minute, second, microsecond \\ {0, 0}, calendar \\ Calendar.ISO)

  def new(hour, minute, second, microsecond, calendar) when is_integer(microsecond) do
    new(hour, minute, second, {microsecond, 6}, calendar)
  end

  def new(hour, minute, second, {microsecond, precision}, calendar)
      when is_integer(hour) and is_integer(minute) and is_integer(second) and
             is_integer(microsecond) and is_integer(precision) do
    case calendar.valid_time?(hour, minute, second, {microsecond, precision}) do
      true ->
        time = %Time{
          hour: hour,
          minute: minute,
          second: second,
          microsecond: {microsecond, precision},
          calendar: calendar
        }

        {:ok, time}

      false ->
        {:error, :invalid_time}
    end
  end

  @doc """
  Converts the given `time` to a string.

  ### Examples

      iex> Time.to_string(~T[23:00:00])
      "23:00:00"
      iex> Time.to_string(~T[23:00:00.001])
      "23:00:00.001"
      iex> Time.to_string(~T[23:00:00.123456])
      "23:00:00.123456"

      iex> Time.to_string(~N[2015-01-01 23:00:00.001])
      "23:00:00.001"
      iex> Time.to_string(~N[2015-01-01 23:00:00.123456])
      "23:00:00.123456"

  """
  @spec to_string(Calendar.time()) :: String.t()
  def to_string(time)

  def to_string(%{
        hour: hour,
        minute: minute,
        second: second,
        microsecond: microsecond,
        calendar: calendar
      }) do
    calendar.time_to_string(hour, minute, second, microsecond)
  end

  @doc """
  Parses the extended "Local time" format described by
  [ISO 8601:2004](https://en.wikipedia.org/wiki/ISO_8601).

  Timezone offset may be included in the string but they will be
  simply discarded as such information is not included in times.

  As specified in the standard, the separator "T" may be omitted if
  desired as there is no ambiguity within this function.

  Time representations with reduced accuracy are not supported.

  Note that while ISO8601 allows times to specify 24:00:00 as the
  zero hour of the next day, this notation is not supported by Elixir.

  ## Examples

      iex> Time.from_iso8601("23:50:07")
      {:ok, ~T[23:50:07]}
      iex> Time.from_iso8601("23:50:07Z")
      {:ok, ~T[23:50:07]}
      iex> Time.from_iso8601("T23:50:07Z")
      {:ok, ~T[23:50:07]}

      iex> Time.from_iso8601("23:50:07,0123456")
      {:ok, ~T[23:50:07.012345]}
      iex> Time.from_iso8601("23:50:07.0123456")
      {:ok, ~T[23:50:07.012345]}
      iex> Time.from_iso8601("23:50:07.123Z")
      {:ok, ~T[23:50:07.123]}

      iex> Time.from_iso8601("2015:01:23 23-50-07")
      {:error, :invalid_format}
      iex> Time.from_iso8601("23:50:07A")
      {:error, :invalid_format}
      iex> Time.from_iso8601("23:50:07.")
      {:error, :invalid_format}
      iex> Time.from_iso8601("23:50:61")
      {:error, :invalid_time}

  """
  @spec from_iso8601(String.t(), Calendar.calendar()) :: {:ok, t} | {:error, atom}
  def from_iso8601(string, calendar \\ Calendar.ISO)

  def from_iso8601(<<?T, h, rest::binary>>, calendar) when h in ?0..?9 do
    from_iso8601(<<h, rest::binary>>, calendar)
  end

  def from_iso8601(<<hour::2-bytes, ?:, min::2-bytes, ?:, sec::2-bytes, rest::binary>>, calendar) do
    with {hour, ""} <- Integer.parse(hour),
         {min, ""} <- Integer.parse(min),
         {sec, ""} <- Integer.parse(sec),
         {microsec, rest} <- Calendar.ISO.parse_microsecond(rest),
         {_offset, ""} <- Calendar.ISO.parse_offset(rest) do
      with {:ok, utc_time} <- new(hour, min, sec, microsec, Calendar.ISO),
           do: convert(utc_time, calendar)
    else
      _ -> {:error, :invalid_format}
    end
  end

  def from_iso8601(<<_::binary>>, _calendar) do
    {:error, :invalid_format}
  end

  @doc """
  Parses the extended "Local time" format described by
  [ISO 8601:2004](https://en.wikipedia.org/wiki/ISO_8601).

  Raises if the format is invalid.

  ## Examples

      iex> Time.from_iso8601!("23:50:07,123Z")
      ~T[23:50:07.123]
      iex> Time.from_iso8601!("23:50:07.123Z")
      ~T[23:50:07.123]
      iex> Time.from_iso8601!("2015:01:23 23-50-07")
      ** (ArgumentError) cannot parse "2015:01:23 23-50-07" as time, reason: :invalid_format
  """
  @spec from_iso8601!(String.t(), Calendar.calendar()) :: t
  def from_iso8601!(string, calendar \\ Calendar.ISO) do
    case from_iso8601(string, calendar) do
      {:ok, value} ->
        value

      {:error, reason} ->
        raise ArgumentError, "cannot parse #{inspect(string)} as time, reason: #{inspect(reason)}"
    end
  end

  @doc """
  Converts the given time to
  [ISO 8601:2004](https://en.wikipedia.org/wiki/ISO_8601).

  By default, `Time.to_iso8601/2` returns times formatted in the "extended"
  format, for human readability. It also supports the "basic" format through
  passing the `:basic` option.

  ### Examples

      iex> Time.to_iso8601(~T[23:00:13])
      "23:00:13"

      iex> Time.to_iso8601(~T[23:00:13.001])
      "23:00:13.001"

      iex> Time.to_iso8601(~T[23:00:13.001], :basic)
      "230013.001"

      iex> Time.to_iso8601(~N[2010-04-17 23:00:13])
      "23:00:13"

  """
  @spec to_iso8601(Calendar.time(), :extended | :basic) :: String.t()
  def to_iso8601(time, format \\ :extended) when format in [:extended, :basic] do
    %{
      hour: hour,
      minute: minute,
      second: second,
      microsecond: microsecond
    } = convert!(time, Calendar.ISO)

    Calendar.ISO.time_to_iso8601(hour, minute, second, microsecond, format)
  end

  @doc """
  Converts given `time` to an Erlang time tuple.

  WARNING: Loss of precision may occur, as Erlang time tuples
  only contain hours/minutes/seconds.

  ## Examples

      iex> Time.to_erl(~T[23:30:15.999])
      {23, 30, 15}

      iex> Time.to_erl(~N[2010-04-17 23:30:15.999])
      {23, 30, 15}

  """
  @spec to_erl(Calendar.time()) :: :calendar.time()
  def to_erl(time) do
    %{hour: hour, minute: minute, second: second} = convert!(time, Calendar.ISO)
    {hour, minute, second}
  end

  @doc """
  Converts an Erlang time tuple to a `Time` struct.

  ## Examples

      iex> Time.from_erl({23, 30, 15}, {5000, 3})
      {:ok, ~T[23:30:15.005]}
      iex> Time.from_erl({24, 30, 15})
      {:error, :invalid_time}

  """
  @spec from_erl(:calendar.time(), Calendar.microsecond(), Calendar.calendar()) ::
          {:ok, t} | {:error, atom}
  def from_erl(tuple, microsecond \\ {0, 0}, calendar \\ Calendar.ISO)

  def from_erl({hour, minute, second}, microsecond, calendar) do
    with {:ok, time} <- new(hour, minute, second, microsecond, Calendar.ISO),
         do: convert(time, calendar)
  end

  @doc """
  Converts an Erlang time tuple to a `Time` struct.

  ## Examples

      iex> Time.from_erl!({23, 30, 15})
      ~T[23:30:15]
      iex> Time.from_erl!({23, 30, 15}, {5000, 3})
      ~T[23:30:15.005]
      iex> Time.from_erl!({24, 30, 15})
      ** (ArgumentError) cannot convert {24, 30, 15} to time, reason: :invalid_time

  """
  @spec from_erl!(:calendar.time(), Calendar.microsecond(), Calendar.calendar()) :: t
  def from_erl!(tuple, microsecond \\ {0, 0}, calendar \\ Calendar.ISO) do
    case from_erl(tuple, microsecond, calendar) do
      {:ok, value} ->
        value

      {:error, reason} ->
        raise ArgumentError,
              "cannot convert #{inspect(tuple)} to time, reason: #{inspect(reason)}"
    end
  end

  @doc """
  Adds the `number` of `unit`s to the given `time`.

  This function accepts the `number` measured according to `Calendar.ISO`.
  The time is returned in the same calendar as it was given in.

  Note the result value represents the time of day, meaning that it is cyclic,
  for instance, it will never go over 24 hours for the ISO calendar.

  ## Examples

      iex> Time.add(~T[10:00:00], 27000)
      ~T[17:30:00.000000]
      iex> Time.add(~T[11:00:00.005], 2400)
      ~T[11:40:00.005000]
      iex> Time.add(~T[00:00:00], 86399999, :millisecond)
      ~T[23:59:59.999000]
      iex> Time.add(~T[17:10:05], 86400)
      ~T[17:10:05.000000]
      iex> Time.add(~T[23:00:00], -60)
      ~T[22:59:00.000000]

  """
  @spec add(Calendar.time(), integer, System.time_unit()) :: t
  def add(%{calendar: calendar} = time, number, unit \\ :second) when is_integer(number) do
    number = System.convert_time_unit(number, unit, :microsecond)
    iso_days = {0, to_day_fraction(time)}
    total = Calendar.ISO.iso_days_to_unit(iso_days, :microsecond) + number
    iso_ppd = 86_400_000_000
    parts = Integer.mod(total, iso_ppd)

    {hour, minute, second, microsecond} = calendar.time_from_day_fraction({parts, iso_ppd})

    %Time{
      hour: hour,
      minute: minute,
      second: second,
      microsecond: microsecond,
      calendar: calendar
    }
  end

  @doc """
  Compares two time structs.

  Returns `:gt` if first time is later than the second
  and `:lt` for vice versa. If the two times are equal
  `:eq` is returned.

  ## Examples

      iex> Time.compare(~T[16:04:16], ~T[16:04:28])
      :lt
      iex> Time.compare(~T[16:04:16], ~T[16:04:16])
      :eq
      iex> Time.compare(~T[16:04:16.01], ~T[16:04:16.001])
      :gt

  This function can also be used to compare across more
  complex calendar types by considering only the time fields:

      iex> Time.compare(~N[1900-01-01 16:04:16], ~N[2015-01-01 16:04:16])
      :eq
      iex> Time.compare(~N[2015-01-01 16:04:16], ~N[2015-01-01 16:04:28])
      :lt
      iex> Time.compare(~N[2015-01-01 16:04:16.01], ~N[2000-01-01 16:04:16.001])
      :gt

  """
  @spec compare(Calendar.time(), Calendar.time()) :: :lt | :eq | :gt
  def compare(%{calendar: calendar} = time1, %{calendar: calendar} = time2) do
    %{hour: hour1, minute: minute1, second: second1, microsecond: {microsecond1, _}} = time1
    %{hour: hour2, minute: minute2, second: second2, microsecond: {microsecond2, _}} = time2

    case {{hour1, minute1, second1, microsecond1}, {hour2, minute2, second2, microsecond2}} do
      {first, second} when first > second -> :gt
      {first, second} when first < second -> :lt
      _ -> :eq
    end
  end

  def compare(time1, time2) do
    {parts1, ppd1} = to_day_fraction(time1)
    {parts2, ppd2} = to_day_fraction(time2)

    case {parts1 * ppd2, parts2 * ppd1} do
      {first, second} when first > second -> :gt
      {first, second} when first < second -> :lt
      _ -> :eq
    end
  end

  @doc """
  Converts given `time` to a different calendar.

  Returns `{:ok, time}` if the conversion was successful,
  or `{:error, reason}` if it was not, for some reason.

  ## Examples

  Imagine someone implements `Calendar.Holocene`, a calendar based on the
  Gregorian calendar that adds exactly 10,000 years to the current Gregorian
  year:

      iex> Time.convert(~T[13:30:15], Calendar.Holocene)
      {:ok, %Time{calendar: Calendar.Holocene, hour: 13, minute: 30, second: 15, microsecond: {0, 0}}}

  """
  @spec convert(Calendar.time(), Calendar.calendar()) :: {:ok, t} | {:error, atom}

  # Keep it multiline for proper function clause errors.
  def convert(
        %{
          calendar: calendar,
          hour: hour,
          minute: minute,
          second: second,
          microsecond: microsecond
        },
        calendar
      ) do
    time = %Time{
      calendar: calendar,
      hour: hour,
      minute: minute,
      second: second,
      microsecond: microsecond
    }

    {:ok, time}
  end

  def convert(%{microsecond: {_, precision}} = time, calendar) do
    {hour, minute, second, {microsecond, _}} =
      time
      |> to_day_fraction()
      |> calendar.time_from_day_fraction()

    time = %Time{
      calendar: calendar,
      hour: hour,
      minute: minute,
      second: second,
      microsecond: {microsecond, precision}
    }

    {:ok, time}
  end

  @doc """
  Similar to `Time.convert/2`, but raises an `ArgumentError`
  if the conversion between the two calendars is not possible.

  ## Examples

  Imagine someone implements `Calendar.Holocene`, a calendar based on the
  Gregorian calendar that adds exactly 10,000 years to the current Gregorian
  year:

      iex> Time.convert!(~T[13:30:15], Calendar.Holocene)
      %Time{calendar: Calendar.Holocene, hour: 13, minute: 30, second: 15, microsecond: {0, 0}}

  """
  @spec convert!(Calendar.time(), Calendar.calendar()) :: t
  def convert!(time, calendar) do
    case convert(time, calendar) do
      {:ok, value} ->
        value

      {:error, reason} ->
        raise ArgumentError,
              "cannot convert #{inspect(time)} to target calendar #{inspect(calendar)}, " <>
                "reason: #{inspect(reason)}"
    end
  end

  @doc """
  Returns the difference between two times, considering only the hour, minute
  second and microsecond.

  As with the `compare/2` function both `Time` structs and other structures
  containing time can be used. If for instance a `NaiveDateTime` or `DateTime`
  is passed, only the hour, month, second, and microsecond is considered. Any
  additional information about a date or time zone is ignored when calculating
  the difference.

  The answer can be returned in any `unit` available from
  `t:System.time_unit/0`. If the first unit is smaller than
  the second, a negative number is returned.

  This function returns the difference in seconds where seconds
  are measured according to `Calendar.ISO`.

  ## Examples

      iex> Time.diff(~T[00:29:12], ~T[00:29:10])
      2

      # When passing a `NaiveDateTime` the date part is ignored.
      iex> Time.diff(~N[2017-01-01 00:29:12], ~T[00:29:10])
      2

      # Two `NaiveDateTime` structs could have big differences in the date
      # but only the time part is considered.
      iex> Time.diff(~N[2017-01-01 00:29:12], (~N[1900-02-03 00:29:10]))
      2

      iex> Time.diff(~T[00:29:12], ~T[00:29:10], :microsecond)
      2_000_000
      iex> Time.diff(~T[00:29:10], ~T[00:29:12], :microsecond)
      -2_000_000

  """
  @spec diff(Calendar.time(), Calendar.time(), System.time_unit()) :: integer
  def diff(time1, time2, unit \\ :second) do
    fraction1 = to_day_fraction(time1)
    fraction2 = to_day_fraction(time2)

    Calendar.ISO.iso_days_to_unit({0, fraction1}, unit) -
      Calendar.ISO.iso_days_to_unit({0, fraction2}, unit)
  end

  ## Helpers

  defp to_day_fraction(%{
         hour: hour,
         minute: minute,
         second: second,
         microsecond: {_, _} = microsecond,
         calendar: calendar
       }) do
    calendar.time_to_day_fraction(hour, minute, second, microsecond)
  end

  defimpl String.Chars do
    def to_string(time) do
      %{
        hour: hour,
        minute: minute,
        second: second,
        microsecond: microsecond,
        calendar: calendar
      } = time

      calendar.time_to_string(hour, minute, second, microsecond)
    end
  end

  defimpl Inspect do
    def inspect(%{calendar: Calendar.ISO} = time, _) do
      %{
        hour: hour,
        minute: minute,
        second: second,
        microsecond: microsecond,
        calendar: Calendar.ISO
      } = time

      "~T[" <> Calendar.ISO.time_to_string(hour, minute, second, microsecond) <> "]"
    end

    def inspect(time, opts) do
      Inspect.Any.inspect(time, opts)
    end
  end
end
