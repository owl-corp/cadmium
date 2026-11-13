defmodule Cadmium.Isotope.RingBufferTest do
  use ExUnit.Case, async: true

  alias Cadmium.Isotope.RingBuffer

  setup do
    name = :"ring_buffer_test_#{System.unique_integer([:positive])}"
    start_supervised!({RingBuffer, name: name, capacity: 4})
    %{rb: name}
  end

  test "an empty series has no items", %{rb: rb} do
    assert RingBuffer.latest(rb, :node) == nil
    assert RingBuffer.last(rb, :node, 10) == []
    assert RingBuffer.size(rb, :node) == 0
    assert RingBuffer.series(rb) == []
  end

  test "returns the latest item and the last n, oldest first", %{rb: rb} do
    for i <- 1..3, do: RingBuffer.push(rb, :node, i)

    assert RingBuffer.latest(rb, :node) == 3
    assert RingBuffer.last(rb, :node, 2) == [2, 3]
    assert RingBuffer.last(rb, :node, 3) == [1, 2, 3]
    assert RingBuffer.last(rb, :node, 100) == [1, 2, 3]
    assert RingBuffer.size(rb, :node) == 3
  end

  test "overwrites the oldest items once full", %{rb: rb} do
    for i <- 1..11, do: RingBuffer.push(rb, :node, i)

    assert RingBuffer.last(rb, :node, 100) == [8, 9, 10, 11]
    assert RingBuffer.last(rb, :node, 2) == [10, 11]
    assert RingBuffer.latest(rb, :node) == 11
    assert RingBuffer.size(rb, :node) == 4
  end

  test "never holds more than capacity rows per series", %{rb: rb} do
    before = :ets.info(rb, :size)
    for i <- 1..1_000, do: RingBuffer.push(rb, :node, i)

    assert :ets.info(rb, :size) - before == 4
  end

  test "series are independent", %{rb: rb} do
    RingBuffer.push(rb, :node, :n1)
    for i <- 1..6, do: RingBuffer.push(rb, {:pod, "a"}, {:a, i})
    RingBuffer.push(rb, {:pod, "b"}, {:b, 1})

    assert RingBuffer.last(rb, :node, 10) == [:n1]
    assert RingBuffer.last(rb, {:pod, "a"}, 10) == for(i <- 3..6, do: {:a, i})
    assert RingBuffer.last(rb, {:pod, "b"}, 10) == [{:b, 1}]
    assert Enum.sort(RingBuffer.series(rb)) == Enum.sort([:node, {:pod, "a"}, {:pod, "b"}])
  end

  test "deleting a series frees all of its rows and leaves the others alone", %{rb: rb} do
    empty = :ets.info(rb, :size)
    for i <- 1..9, do: RingBuffer.push(rb, {:pod, "a"}, i)
    RingBuffer.push(rb, :node, :kept)

    assert RingBuffer.delete(rb, {:pod, "a"}) == :ok

    assert RingBuffer.last(rb, {:pod, "a"}, 10) == []
    assert RingBuffer.latest(rb, {:pod, "a"}) == nil
    assert RingBuffer.series(rb) == [:node]
    assert RingBuffer.latest(rb, :node) == :kept
    assert :ets.info(rb, :size) == empty + 1

    # deleting again, or something that never existed, is fine
    assert RingBuffer.delete(rb, {:pod, "a"}) == :ok
    assert RingBuffer.delete(rb, {:pod, "nope"}) == :ok
  end

  test "a deleted series starts afresh", %{rb: rb} do
    for i <- 1..6, do: RingBuffer.push(rb, :s, i)
    RingBuffer.delete(rb, :s)
    RingBuffer.push(rb, :s, :new)

    assert RingBuffer.last(rb, :s, 10) == [:new]
  end

  test "can be read from other processes", %{rb: rb} do
    RingBuffer.push(rb, :node, 1)
    assert Task.await(Task.async(fn -> RingBuffer.latest(rb, :node) end)) == 1
  end

  test "readers racing a writer only ever see consecutive items in order", %{rb: rb} do
    writer =
      Task.async(fn ->
        for i <- 1..20_000, do: RingBuffer.push(rb, :node, i)
      end)

    for _ <- 1..2_000 do
      items = RingBuffer.last(rb, :node, 4)
      assert items == Enum.sort(items)
      assert items == Enum.uniq(items)
    end

    Task.await(writer)
    assert RingBuffer.last(rb, :node, 4) == [19_997, 19_998, 19_999, 20_000]
  end

  test "reads on a buffer that does not exist are empty" do
    refute RingBuffer.exists?(:no_such_ring_buffer)
    assert RingBuffer.latest(:no_such_ring_buffer, :node) == nil
    assert RingBuffer.last(:no_such_ring_buffer, :node, 5) == []
    assert RingBuffer.size(:no_such_ring_buffer, :node) == 0
    assert RingBuffer.series(:no_such_ring_buffer) == []
    assert RingBuffer.delete(:no_such_ring_buffer, :node) == :ok
  end

  test "new/2 creates a buffer owned by the caller" do
    name = :"ring_buffer_test_#{System.unique_integer([:positive])}"

    task =
      Task.async(fn ->
        RingBuffer.new(name, 2)
        for i <- 1..3, do: RingBuffer.push(name, :s, i)
        {RingBuffer.exists?(name), RingBuffer.last(name, :s, 5)}
      end)

    assert Task.await(task) == {true, [2, 3]}
  end
end
