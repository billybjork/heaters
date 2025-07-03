defmodule Heaters.Utils do
  @moduledoc """
  Shared utility functions for the Heaters application.

  This module contains common helper functions used across different
  parts of the video processing pipeline.
  """

  @doc """
  Sanitizes a filename by replacing invalid characters with underscores.

  This function:
  - Only allows ASCII alphanumeric characters, hyphens, and underscores for S3 compatibility
  - Replaces all other characters (including Unicode) with underscores
  - Collapses multiple consecutive underscores into a single underscore
  - Trims leading and trailing underscores
  - Ensures the result is not empty (returns "default" if empty)

  ## Examples

      iex> Heaters.Utils.sanitize_filename("My Video Title!")
      "My_Video_Title"

      iex> Heaters.Utils.sanitize_filename("test__file___name")
      "test_file_name"

      iex> Heaters.Utils.sanitize_filename("_leading_and_trailing_")
      "leading_and_trailing"

      iex> Heaters.Utils.sanitize_filename("www.youtube.com")
      "www_youtube_com"

      iex> Heaters.Utils.sanitize_filename("Video with émojis 🎬 and 中文")
      "Video_with_mojis_and"

      iex> Heaters.Utils.sanitize_filename("")
      "default"

      iex> Heaters.Utils.sanitize_filename("___")
      "default"
  """
  @spec sanitize_filename(String.t()) :: String.t()
  def sanitize_filename(filename) when is_binary(filename) do
    result =
      filename
      # Only allow ASCII alphanumeric, hyphens, and underscores
      |> String.replace(~r/[^a-zA-Z0-9\-_]/, "_", global: true)
      # Collapse multiple consecutive underscores
      |> String.replace(~r/_{2,}/, "_", global: true)
      # Trim leading and trailing underscores
      |> String.trim("_")

    # Ensure we don't return an empty string
    case result do
      "" -> "default"
      sanitized -> sanitized
    end
  end

  def sanitize_filename(_), do: "default"
end
