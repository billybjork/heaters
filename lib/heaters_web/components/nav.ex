defmodule HeatersWeb.Nav do
  @moduledoc "Site-wide top toolbar (Review / Query links)."

  use Phoenix.Component
  # <─ supplies the ~p sigil
  use HeatersWeb, :verified_routes

  alias Heaters.Media.Clips

  # handy later for an "active" class; not used yet
  attr(:current_path, :string, required: true)

  def nav(assigns) do
    assigns =
      assign_new(assigns, :pending_count, fn ->
        Clips.pending_review_count()
      end)

    ~H"""
    <header class="site-nav">
      <nav class="nav-container">

    <!-- Review link + badge (hidden when zero) -->
        <.link navigate={~p"/review"} class="nav-link relative">
          Review
          <%= if @pending_count > 0 do %>
            <span class="badge">{@pending_count}</span>
          <% end %>
        </.link>

        <.link navigate={~p"/query"} class="nav-link">Query</.link>

        <.link href="http://localhost:4200/" target="_blank" class="nav-link">
          Prefect
        </.link>

    <!-- ───────── Quick-submit form ───────── -->
        <form action={~p"/submit_video"} method="post" class="submit-form">
          <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
          <input type="url" name="url" placeholder="Paste video URL…" required class="submit-input" />
          <button class="btn-small" type="submit">Submit</button>
        </form>
      </nav>
    </header>
    """
  end
end
