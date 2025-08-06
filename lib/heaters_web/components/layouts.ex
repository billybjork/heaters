defmodule HeatersWeb.Layouts do
  use HeatersWeb, :html

  @doc """
  Phoenix 1.8 app layout component with flash message handling.
  
  Usage in LiveView templates:
    <Layouts.app flash={@flash}>
      <!-- Your content here -->
    </Layouts.app>
  """
  attr :flash, :map, required: true
  attr :full_width, :boolean, default: false

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <% container_class = if @full_width, do: "full-width", else: "container" %>
    
    <main class="main-content">
      <div class={container_class}>
        <.render_flash flash={@flash} />
        {render_slot(@inner_block)}
      </div>
    </main>
    """
  end

  # Renders flash messages consistently across the app.
  attr :flash, :map, required: true

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