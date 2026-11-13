defmodule Cadmium.Catalyst.Config do
  @moduledoc """
  Snapshot of `config :cadmium, Cadmium.Catalyst`.

  Loaded fresh at the start of every evaluation so a cycle sees one consistent set of
  thresholds. `load/1` accepts keyword overrides (used by tests and by processes started
  with a `:config` option); unknown keys are ignored.
  """

  @type t :: %__MODULE__{
          enabled: boolean(),
          dry_run: boolean(),
          evaluate_interval_ms: pos_integer(),
          hot_threshold: number(),
          spread_threshold: number(),
          sustained_ms: non_neg_integer(),
          node_cooldown_ms: non_neg_integer(),
          workload_cooldown_ms: non_neg_integer(),
          max_evictions_per_cycle: non_neg_integer(),
          taint_key: String.t(),
          opt_out_annotation: String.t(),
          excluded_namespaces: [String.t()],
          audit_log_size: pos_integer()
        }

  defstruct enabled: true,
            dry_run: true,
            evaluate_interval_ms: 15_000,
            hot_threshold: 70.0,
            spread_threshold: 25.0,
            sustained_ms: 120_000,
            node_cooldown_ms: 300_000,
            workload_cooldown_ms: 900_000,
            max_evictions_per_cycle: 1,
            taint_key: "cadmium.owl-corp.io/hot",
            opt_out_annotation: "cadmium.owl-corp.io/rebalance",
            excluded_namespaces: ["kube-system"],
            audit_log_size: 500

  @keys [
    :enabled,
    :dry_run,
    :evaluate_interval_ms,
    :hot_threshold,
    :spread_threshold,
    :sustained_ms,
    :node_cooldown_ms,
    :workload_cooldown_ms,
    :max_evictions_per_cycle,
    :taint_key,
    :opt_out_annotation,
    :excluded_namespaces,
    :audit_log_size
  ]

  @spec load(keyword() | t()) :: t()
  def load(overrides \\ [])
  def load(%__MODULE__{} = config), do: config

  def load(overrides) when is_list(overrides) do
    fields =
      :cadmium
      |> Application.get_env(Cadmium.Catalyst, [])
      |> Keyword.merge(overrides)
      |> Keyword.take(@keys)

    struct(__MODULE__, fields)
  end

  @doc "The taint Cadmium puts on a hot node while it is being relieved."
  @spec taint(t()) :: Cadmium.Kube.Node.taint()
  def taint(%__MODULE__{taint_key: key}),
    do: %{key: key, value: "true", effect: "PreferNoSchedule"}

  @doc """
  Highest score (exclusive) a node may have to count as a destination: the hot threshold
  minus half the spread threshold (57.5 with the defaults). See `Cadmium.Catalyst.Policy`.
  """
  @spec cool_ceiling(t()) :: float()
  def cool_ceiling(%__MODULE__{hot_threshold: hot, spread_threshold: spread}),
    do: hot - spread / 2
end
