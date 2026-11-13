defmodule Cadmium.IsotopeScriptedSource do
  @moduledoc """
  A `Cadmium.Isotope.Source` for tests that plays back a script.

  Pass `script: pid`, where `pid` comes from `start_script/1`. Each `read/1` consumes the
  next step:

    * `{:ok, reading}` - a successful reading
    * `{:error, reason}` - a failed reading
    * `{:raise, message}` / `{:exit, reason}` / `{:throw, value}` - blow up
    * `{:return, term}` - return `term` verbatim (to test bad return values)

  An exhausted script fails with `:script_exhausted`. `init_script: pid` does the same for
  `init/1` with the steps `:ok`, `{:error, reason}` and `{:raise, message}`; once it is
  exhausted (or if it is not given) init succeeds.
  """

  @behaviour Cadmium.Isotope.Source

  def start_script(steps), do: Agent.start_link(fn -> steps end)

  def push(script, steps), do: Agent.update(script, &(&1 ++ List.wrap(steps)))

  @impl true
  def init(opts) do
    case opts[:init_script] && pop(opts[:init_script]) do
      {:error, reason} -> {:error, reason}
      {:raise, message} -> raise message
      _ -> {:ok, Keyword.fetch!(opts, :script)}
    end
  end

  @impl true
  def read(script) do
    case pop(script) do
      {:ok, reading} -> {:ok, reading, script}
      {:error, reason} -> {:error, reason, script}
      {:raise, message} -> raise message
      {:exit, reason} -> exit(reason)
      {:throw, value} -> throw(value)
      {:return, term} -> term
      nil -> {:error, :script_exhausted, script}
    end
  end

  defp pop(script) do
    Agent.get_and_update(script, fn
      [step | rest] -> {step, rest}
      [] -> {nil, []}
    end)
  end
end
