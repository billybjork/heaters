defmodule Heaters.Clips.Operations.Keyframe.PythonArgs do
  @moduledoc """
  Pure Python argument construction functions for keyframe extraction.
  Used by Transform.Keyframe for business logic.
  """

  alias Heaters.Clips.Operations.Keyframe.Strategy

  @type python_args :: %{
          clip_id: integer(),
          input_s3_path: String.t(),
          output_s3_prefix: String.t(),
          keyframe_params: map()
        }

  @doc """
  Builds Python arguments for keyframe extraction.

  ## Parameters
  - `clip`: Clip struct with id and clip_filepath
  - `artifact_prefix`: S3 prefix for output artifacts
  - `strategy_config`: Strategy configuration from Strategy.configure_strategy/1

  ## Returns
  - `python_args()` structure for PyRunner
  """
  @spec build_python_args(map(), String.t(), Strategy.strategy_config()) :: python_args()
  def build_python_args(
        %{id: clip_id, clip_filepath: clip_filepath},
        artifact_prefix,
        strategy_config
      ) do
    %{
      clip_id: clip_id,
      input_s3_path: normalize_s3_path(clip_filepath),
      output_s3_prefix: artifact_prefix,
      keyframe_params: build_keyframe_params(strategy_config)
    }
  end

  @doc """
  Builds keyframe parameters for Python script.

  ## Parameters
  - `strategy_config`: Strategy configuration with strategy and count

  ## Returns
  - Map with keyframe parameters
  """
  @spec build_keyframe_params(Strategy.strategy_config()) :: map()
  def build_keyframe_params(%{strategy: strategy, count: count}) do
    %{
      strategy: strategy,
      count: count
    }
  end

  @doc """
  Validates that Python arguments are properly constructed.

  ## Parameters
  - `python_args`: Python arguments to validate

  ## Returns
  - `:ok` if arguments are valid
  - `{:error, String.t()}` if arguments are invalid
  """
  @spec validate_python_args(python_args()) :: :ok | {:error, String.t()}
  def validate_python_args(%{
        clip_id: clip_id,
        input_s3_path: input_path,
        output_s3_prefix: output_prefix,
        keyframe_params: params
      })
      when is_integer(clip_id) and is_binary(input_path) and is_binary(output_prefix) and
             is_map(params) do
    with :ok <- validate_s3_path(input_path),
         :ok <- validate_keyframe_params(params) do
      :ok
    end
  end

  def validate_python_args(invalid_args) do
    {:error, "Invalid Python arguments structure: #{inspect(invalid_args)}"}
  end

  @doc """
  Builds a descriptive task name for logging purposes.

  ## Parameters
  - `clip_id`: Clip ID
  - `strategy`: Keyframe strategy

  ## Returns
  - Descriptive task name string
  """
  @spec build_task_description(integer(), String.t()) :: String.t()
  def build_task_description(clip_id, strategy) do
    "keyframe_extraction_clip_#{clip_id}_#{strategy}"
  end

  ## Private helper functions

  @spec normalize_s3_path(String.t()) :: String.t()
  defp normalize_s3_path(s3_path) do
    String.trim_leading(s3_path, "/")
  end

  @spec validate_s3_path(String.t()) :: :ok | {:error, String.t()}
  defp validate_s3_path(path) when is_binary(path) and path != "" do
    :ok
  end

  defp validate_s3_path(invalid_path) do
    {:error, "Invalid S3 path: #{inspect(invalid_path)}"}
  end

  @spec validate_keyframe_params(map()) :: :ok | {:error, String.t()}
  defp validate_keyframe_params(%{strategy: strategy, count: count})
       when is_binary(strategy) and is_integer(count) and count > 0 do
    :ok
  end

  defp validate_keyframe_params(invalid_params) do
    {:error, "Invalid keyframe parameters: #{inspect(invalid_params)}"}
  end
end
