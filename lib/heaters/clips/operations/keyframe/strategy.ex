defmodule Heaters.Clips.Operations.Keyframe.Strategy do
  @moduledoc """
  Pure domain functions for keyframe extraction strategy selection.
  Used by Operations.Keyframe for business logic.
  """

  @valid_strategies ~w[midpoint multi]

  @type strategy_config :: %{
          strategy: String.t(),
          count: pos_integer(),
          description: String.t()
        }

  @doc """
  Validates and configures keyframe extraction strategy.

  ## Parameters
  - `strategy`: Strategy name ("midpoint" or "multi")

  ## Returns
  - `{:ok, strategy_config()}` on success with count and description
  - `{:error, String.t()}` on invalid strategy
  """
  @spec configure_strategy(String.t()) :: {:ok, strategy_config()} | {:error, String.t()}
  def configure_strategy(strategy) when strategy in @valid_strategies do
    case strategy do
      "midpoint" ->
        {:ok,
         %{
           strategy: strategy,
           count: 1,
           description: "Single keyframe at video midpoint"
         }}

      "multi" ->
        {:ok,
         %{
           strategy: strategy,
           count: 3,
           description: "Multiple keyframes distributed across video"
         }}
    end
  end

  def configure_strategy(invalid_strategy) do
    {:error,
     "Invalid keyframe strategy: '#{invalid_strategy}'. Valid strategies: #{Enum.join(@valid_strategies, ", ")}"}
  end

  @doc """
  Gets the default keyframe strategy configuration.

  ## Returns
  - `strategy_config()` for the default "multi" strategy
  """
  @spec default_strategy() :: strategy_config()
  def default_strategy do
    {:ok, config} = configure_strategy("multi")
    config
  end

  @doc """
  Validates if the given strategy is supported.

  ## Parameters
  - `strategy`: Strategy name to validate

  ## Returns
  - `:ok` if strategy is valid
  - `{:error, String.t()}` if strategy is invalid
  """
  @spec validate_strategy(String.t()) :: :ok | {:error, String.t()}
  def validate_strategy(strategy) when strategy in @valid_strategies, do: :ok

  def validate_strategy(invalid_strategy) do
    {:error, "Unsupported keyframe strategy: '#{invalid_strategy}'"}
  end

  @doc """
  Lists all available keyframe strategies.

  ## Returns
  - List of strategy names
  """
  @spec available_strategies() :: [String.t()]
  def available_strategies, do: @valid_strategies

  @doc """
  Determines if a strategy produces multiple keyframes.

  ## Parameters
  - `strategy`: Strategy name

  ## Returns
  - `true` if strategy produces multiple keyframes
  - `false` if strategy produces single keyframe
  """
  @spec multi_keyframe_strategy?(String.t()) :: boolean()
  def multi_keyframe_strategy?("multi"), do: true
  def multi_keyframe_strategy?("midpoint"), do: false
  def multi_keyframe_strategy?(_), do: false
end
