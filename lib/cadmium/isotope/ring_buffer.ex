defmodule Cadmium.Isotope.RingBuffer do
  @moduledoc """
  Fixed-capacity ring buffers in ETS.

  One buffer (a pair of named ETS tables) holds any number of independent *series* - the
  node series and one series per pod - each keeping its last `capacity` items. Inserting
  is O(1) and overwrites the oldest item once a series is full. Readers go straight to
  ETS from any process and never block the writer.

  Each series must have a single writer process (the sampler). Readers racing with the
  writer may miss the item being written but never see items out of order.

  Start it as a process (`{RingBuffer, name: ..., capacity: ...}`) so the tables outlive a
  crashing writer, or call `new/2` to have the calling process own them.

  All read functions return empty results when the buffer does not exist.
  """

  use GenServer

  @type t :: atom()
  @type series :: term()

  @capacity_key :"$capacity"

  # -- owner process ---------------------------------------------------------------------

  @doc "Starts a process that owns the buffer. Options: `:name` and `:capacity` (required)."
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    capacity = Keyword.fetch!(opts, :capacity)
    GenServer.start_link(__MODULE__, {name, capacity})
  end

  @impl true
  def init({name, capacity}), do: {:ok, new(name, capacity)}

  # -- API -------------------------------------------------------------------------------

  @doc "Creates the buffer `name`, owned by the caller, keeping `capacity` items per series."
  @spec new(t(), pos_integer()) :: t()
  def new(name, capacity) when is_atom(name) and is_integer(capacity) and capacity > 0 do
    :ets.new(name, [:named_table, :set, :public, read_concurrency: true])
    :ets.new(meta(name), [:named_table, :set, :public, read_concurrency: true])
    :ets.insert(name, {@capacity_key, capacity})
    name
  end

  @doc "Whether the buffer exists."
  @spec exists?(t()) :: boolean()
  def exists?(name) do
    :ets.whereis(name) != :undefined and :ets.whereis(meta(name)) != :undefined
  end

  @doc "Appends `item` to `series`, overwriting the oldest item if the series is full."
  @spec push(t(), series(), term()) :: :ok
  def push(name, series, item) do
    meta = meta(name)

    {count, capacity} =
      case :ets.lookup(meta, series) do
        [{_, count, capacity}] -> {count, capacity}
        [] -> {0, :ets.lookup_element(name, @capacity_key, 2)}
      end

    # Slot first, then the count: a concurrent reader either does not know about the new
    # item yet, or finds it in place.
    :ets.insert(name, {{series, rem(count, capacity)}, count, item})
    :ets.insert(meta, {series, count + 1, capacity})
    :ok
  end

  @doc "The most recent item of `series`, or nil."
  @spec latest(t(), series()) :: term() | nil
  def latest(name, series) do
    case last(name, series, 1) do
      [item] -> item
      [] -> nil
    end
  end

  @doc "Up to `n` most recent items of `series`, oldest first."
  @spec last(t(), series(), pos_integer()) :: [term()]
  def last(name, series, n) when is_integer(n) and n > 0 do
    case :ets.lookup(meta(name), series) do
      [{_, count, capacity}] ->
        first = count - min(n, min(count, capacity))

        # The stored sequence number tells us if the writer lapped us and reused the slot.
        for seq <- first..(count - 1)//1,
            [{_, ^seq, item}] <- [:ets.lookup(name, {series, rem(seq, capacity)})],
            do: item

      [] ->
        []
    end
  rescue
    ArgumentError -> []
  end

  def last(_name, _series, _n), do: []

  @doc "Number of items currently held for `series`."
  @spec size(t(), series()) :: non_neg_integer()
  def size(name, series) do
    case :ets.lookup(meta(name), series) do
      [{_, count, capacity}] -> min(count, capacity)
      [] -> 0
    end
  rescue
    ArgumentError -> 0
  end

  @doc "Every series that currently has items."
  @spec series(t()) :: [series()]
  def series(name) do
    :ets.select(meta(name), [{{:"$1", :_, :_}, [], [:"$1"]}])
  rescue
    ArgumentError -> []
  end

  @doc "Removes `series` and all of its items."
  @spec delete(t(), series()) :: :ok
  def delete(name, series) do
    case :ets.take(meta(name), series) do
      [{_, count, capacity}] ->
        for slot <- 0..(min(count, capacity) - 1)//1, do: :ets.delete(name, {series, slot})
        :ok

      [] ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end

  defp meta(name), do: Module.concat(name, "Meta")
end
