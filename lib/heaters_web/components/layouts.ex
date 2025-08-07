defmodule HeatersWeb.Layouts do
  use HeatersWeb, :html

  embed_templates("layouts/*")

  attr(:flash, :map, required: true)

  defp render_flash(assigns) do
    ~H"""
    <%= if info = Phoenix.Flash.get(@flash, :info) do %>
      <div class="flash flash--approve" role="alert" aria-live="polite">
        {info}
      </div>
    <% end %>

    <%= if error = Phoenix.Flash.get(@flash, :error) do %>
      <div class="flash flash--archive" role="alert" aria-live="polite">
        {error}
      </div>
    <% end %>
    """
  end
end
