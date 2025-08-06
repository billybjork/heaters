defmodule HeatersWeb.Layouts do
  use HeatersWeb, :html

  @doc """
  Phoenix 1.8 simplified app layout with slot support.
  
  Usage in LiveViews:
    def render(assigns) do
      ~H\"\"\"
      <Layouts.app flash={@flash}>
        <!-- Your content here -->
      </Layouts.app>
      \"\"\"
    end
  """
  attr :flash, Phoenix.LiveView.AsyncResult, required: true

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <% container_class = if assigns[:full_width], do: "full-width", else: "container" %>
    
    <main class="main-content">
      <div class={container_class}>
        {render_slot(@inner_block)}
      </div>
    </main>
    """
  end

  embed_templates("layouts/*")
end