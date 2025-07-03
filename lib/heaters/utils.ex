defmodule Heaters.Utils do
  @moduledoc """
  Shared utility functions for the Heaters application.

  This module contains common helper functions used across different
  parts of the video processing pipeline.
  """

  @doc """
  Sanitizes a filename by replacing invalid characters with underscores.

  This function:
  - Replaces non-word characters (except hyphens and underscores) with underscores
  - Collapses multiple consecutive underscores into a single underscore
  - Trims leading and trailing underscores

  ## Examples

      iex> Heaters.Utils.sanitize_filename("My Video Title!")
      "My_Video_Title"

      iex> Heaters.Utils.sanitize_filename("test__file___name")
      "test_file_name"

      iex> Heaters.Utils.sanitize_filename("_leading_and_trailing_")
      "leading_and_trailing"

      iex> Heaters.Utils.sanitize_filename("www.youtube.com")
      "www_youtube_com"
  """
  @spec sanitize_filename(String.t()) :: String.t()
  def sanitize_filename(filename) do
    filename
    |> String.replace(~r/[^\w\-_]/, "_", global: true)
    |> String.replace(~r/_{2,}/, "_", global: true)
    |> String.trim("_")
  end
end
