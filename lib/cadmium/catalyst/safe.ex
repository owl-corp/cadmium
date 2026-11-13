defmodule Cadmium.Catalyst.Safe do
  @moduledoc """
  Wrappers that turn raises/exits/throws from a dependency into values.

  Catalyst treats every failure as "no information": callers get a default (or an
  `{:error, _}` tuple) and decide to skip rather than crash half-way through a cycle.
  """

  @doc "Runs `fun`; returns `default` if it raises, exits or throws."
  @spec call((-> term()), term()) :: term()
  def call(fun, default) when is_function(fun, 0) do
    fun.()
  rescue
    _ -> default
  catch
    _, _ -> default
  end

  @doc "Runs a Kubernetes call; failures of any kind become `{:error, reason}`."
  @spec kube((-> term())) :: term()
  def kube(fun) when is_function(fun, 0) do
    fun.()
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  @doc "True only when `fun` returns exactly `true`; anything else (including a crash) is false."
  @spec true?((-> term())) :: boolean()
  def true?(fun) when is_function(fun, 0), do: call(fun, false) == true
end
