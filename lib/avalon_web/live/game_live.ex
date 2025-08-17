defmodule AvalonWeb.GameLive do
  use AvalonWeb, :live_view
  alias Avalon.Game

  def mount(%{"game_id" => game_id}, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Avalon.PubSub, "game:#{game_id}")
      # Start a timer to update the countdown every second
      :timer.send_interval(1000, self(), :tick)
    end

    # Initialize socket - cookies will be loaded via JavaScript
    socket = socket
    |> assign(:game_id, game_id)
    |> assign(:player_id, nil)
    |> assign(:player_name, "")
    |> assign(:game_state, nil)
    |> assign(:selected_team, [])
    |> assign(:error, nil)
    |> assign(:current_time, System.monotonic_time(:millisecond))

    {:ok, socket}
  end

  def handle_event("join_game", %{"player_name" => name}, socket) do
    case Game.join_game(socket.assigns.game_id, name) do
      {:ok, player_id} ->
        Phoenix.PubSub.subscribe(Avalon.PubSub, "game:#{player_id}")

        socket = socket
        |> assign(:player_id, player_id)
        |> assign(:player_name, name)
        |> assign(:error, nil)
        |> set_session_cookies(socket.assigns.game_id, player_id, name)

        {:noreply, socket}

      {:error, reason} ->
        {:noreply, assign(socket, :error, reason)}
    end
  end

  def handle_event("start_game", _, socket) do
    Game.start_game(socket.assigns.game_id)
    {:noreply, socket}
  end

  def handle_event("toggle_team_member", %{"player_id" => player_id}, socket) do
    selected_team = socket.assigns.selected_team

    new_team = if player_id in selected_team do
      List.delete(selected_team, player_id)
    else
      [player_id | selected_team]
    end

    {:noreply, assign(socket, :selected_team, new_team)}
  end

  def handle_event("propose_team", _, socket) do
    Game.propose_team(socket.assigns.game_id, socket.assigns.player_id, socket.assigns.selected_team)
    {:noreply, assign(socket, :selected_team, [])}
  end

  def handle_event("vote", %{"vote" => vote}, socket) do
    vote_atom = if vote == "approve", do: :approve, else: :reject
    Game.vote_on_team(socket.assigns.game_id, socket.assigns.player_id, vote_atom)
    {:noreply, socket}
  end

  def handle_event("play_quest_card", %{"card" => card}, socket) do
    card_atom = if card == "success", do: :success, else: :fail
    Game.play_quest_card(socket.assigns.game_id, socket.assigns.player_id, card_atom)
    {:noreply, socket}
  end

  def handle_event("assassinate", %{"target" => target_id}, socket) do
    Game.assassinate(socket.assigns.game_id, target_id)
    {:noreply, socket}
  end

  def handle_event("use_lady_of_the_lake", %{"target" => target_id}, socket) do
    Game.use_lady_of_the_lake(socket.assigns.game_id, socket.assigns.player_id, target_id)
    {:noreply, socket}
  end

  def handle_event("leave_game", _, socket) do
    # Clear session cookies and redirect to home
    socket = clear_session_cookies(socket)
    {:noreply, push_navigate(socket, to: ~p"/")}
  end

  def handle_event("clear_session", _, socket) do
    # Clear session cookies and refresh the page
    socket = clear_session_cookies(socket)
    {:noreply, push_navigate(socket, to: ~p"/game/#{socket.assigns.game_id}")}
  end

  def handle_event("cookies_loaded", %{"game_id" => game_id, "player_id" => player_id, "player_name" => player_name}, socket) do
    # Handle cookies loaded from JavaScript
    if game_id == socket.assigns.game_id do
      case Game.get_game_state(game_id, player_id) do
        {:ok, game_state} ->
          # Mark player as reconnected
          Game.reconnect_player(game_id, player_id)

          # Clear reconnected flags after 30 seconds
          Process.send_after(self(), :clear_reconnected_flags, 30_000)

          socket = socket
          |> assign(:player_id, player_id)
          |> assign(:player_name, player_name)
          |> assign(:game_state, game_state)
          |> assign(:selected_team, [])
          |> assign(:error, nil)
          |> put_flash(:info, "Welcome back, #{player_name}!")

          {:noreply, socket}
        {:error, _} ->
          # Player not found, clear cookies
          socket = clear_session_cookies(socket)
          {:noreply, assign(socket, :error, "Your previous session has expired. Please join again.")}
      end
    else
      # Different game, clear cookies
      socket = clear_session_cookies(socket)
      {:noreply, assign(socket, :error, "You have a session in a different game. Please join this game with a new name.")}
    end
  end

  def handle_info(:tick, socket) do
    # Update current time for countdown calculations
    socket = assign(socket, :current_time, System.monotonic_time(:millisecond))
    {:noreply, socket}
  end

  def handle_info({:game_update, game_state}, socket) do
    # Clear cookies if game is over
    socket = if game_state.phase == :game_over do
      clear_session_cookies(socket)
    else
      socket
    end

    {:noreply, assign(socket, :game_state, game_state)}
  end

  def handle_info(:clear_reconnected_flags, socket) do
    Game.clear_reconnected_flags(socket.assigns.game_id)
    {:noreply, socket}
  end

  def render(assigns) do
    ~H"""
    <%= render_styles(assigns) %>
    <div class="avalon-game">
      <%= if @player_id do %>
        <div class="game-interface">
          <div class="game-header">
            <h2>Game: <%= @game_id %></h2>
            <button phx-click="leave_game" class="leave-game-btn">Leave Game</button>
          </div>
          <%= render_game_phase(assigns) %>
        </div>
      <% else %>
        <div class="join-form">
          <h2>Join Avalon Game</h2>
          <form phx-submit="join_game">
            <input type="text" name="player_name" placeholder="Enter your name" required />
            <button type="submit">Join Game</button>
          </form>
          <button phx-click="clear_session" class="clear-session-btn">Join as Different Player</button>
          <%= if @error do %>
            <div class="error"><%= @error %></div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  defp render_game_phase(%{game_state: nil} = assigns) do
    ~H"""
    <div>Loading game...</div>
    """
  end

  defp render_game_phase(%{game_state: %{phase: :lobby}} = assigns) do
    ~H"""
    <div class="lobby">
      <h2>Waiting for players...</h2>
      <div class="players">
        <%= for player_id <- @game_state.player_order do %>
          <div class="player">
            <%= @game_state.players[player_id].name %>
            <%= if @game_state.players[player_id].reconnected do %>
              <span class="reconnected-badge">Reconnected</span>
            <% end %>
          </div>
        <% end %>
      </div>
      <%= if length(@game_state.player_order) >= 5 do %>
        <button phx-click="start_game">Start Game</button>
      <% else %>
        <p>Need at least 5 players to start</p>
      <% end %>
    </div>
    """
  end

  defp render_game_phase(%{game_state: %{phase: :team_building}} = assigns) do
    ~H"""
    <div class="team-building">
      <h2>Quest <%= @game_state.current_quest %> - Team Building</h2>

      <%= render_timer(assigns) %>
      <%= render_role_info(assigns) %>
      <%= render_quest_status(assigns) %>

      <div class="current-leader">
        Leader: <%= @game_state.players[@game_state.current_leader].name %>
      </div>

      <%= if @game_state.can_propose do %>
        <div class="team-selection">
          <h3>Select your team:</h3>
          <%= for player_id <- @game_state.player_order do %>
            <div class="player-option">
              <input type="checkbox"
                     id={"player_#{player_id}"}
                     phx-click="toggle_team_member"
                     phx-value-player_id={player_id}
                     checked={player_id in @selected_team} />
              <label for={"player_#{player_id}"}>
                <%= @game_state.players[player_id].name %>
              </label>
            </div>
          <% end %>
          <button phx-click="propose_team" disabled={length(@selected_team) != get_required_team_size(@game_state)}>
            Propose Team
          </button>
        </div>
      <% else %>
        <p>Waiting for <%= @game_state.players[@game_state.current_leader].name %> to propose a team...</p>
      <% end %>
    </div>
    """
  end

  defp render_game_phase(%{game_state: %{phase: :voting}} = assigns) do
    ~H"""
    <div class="voting">
      <h2>Quest <%= @game_state.current_quest %> - Team Vote</h2>

      <%= render_timer(assigns) %>
      <%= render_role_info(assigns) %>
      <%= render_quest_status(assigns) %>

      <div class="proposed-team">
        <h3>Proposed Team:</h3>
        <%= for player_id <- @game_state.proposed_team do %>
          <div class="team-member">
            <%= @game_state.players[player_id].name %>
          </div>
        <% end %>
      </div>

      <%= if @game_state.can_vote and not Map.has_key?(@game_state.votes, @player_id) do %>
        <div class="vote-buttons">
          <button phx-click="vote" phx-value-vote="approve">Approve</button>
          <button phx-click="vote" phx-value-vote="reject">Reject</button>
        </div>
      <% else %>
        <p>
          <%= if Map.has_key?(@game_state.votes, @player_id) do %>
            You voted: <%= @game_state.votes[@player_id] %>
          <% else %>
            You will auto-approve if you don't vote in time.
          <% end %>
        </p>
      <% end %>

      <div class="vote-status">
        Votes collected: <%= map_size(@game_state.votes) %>/<%= length(@game_state.player_order) %>
      </div>
    </div>
    """
  end

  defp render_game_phase(%{game_state: %{phase: :quest}} = assigns) do
    ~H"""
    <div class="quest">
      <h2>Quest <%= @game_state.current_quest %> - In Progress</h2>

      <%= render_timer(assigns) %>
      <%= render_role_info(assigns) %>
      <%= render_quest_status(assigns) %>

      <div class="quest-team">
        <h3>Quest Team:</h3>
        <%= for player_id <- @game_state.proposed_team do %>
          <div class="team-member">
            <%= @game_state.players[player_id].name %>
          </div>
        <% end %>
      </div>

      <%= if @game_state.can_play_quest do %>
        <div class="quest-cards">
          <h3>Choose your quest card:</h3>
          <button phx-click="play_quest_card" phx-value-card="success">Success</button>
          <%= if @game_state.role in [:evil, :assassin] do %>
            <button phx-click="play_quest_card" phx-value-card="fail">Fail</button>
          <% end %>
        </div>
      <% else %>
        <p>
          <%= if @game_state.is_on_team do %>
            Waiting for other team members...
          <% else %>
            Waiting for the quest team to play their cards...
          <% end %>
        </p>
      <% end %>

      <div class="quest-status">
        Cards played: <%= length(@game_state.quest_cards || []) %>/<%= length(@game_state.proposed_team) %>
      </div>
    </div>
    """
  end

  defp render_game_phase(%{game_state: %{phase: :assassination}} = assigns) do
    ~H"""
    <div class="assassination">
      <h2>Evil's Last Chance - Assassinate Merlin!</h2>

      <%= render_timer(assigns) %>
      <%= render_quest_status(assigns) %>

      <%= if @game_state.can_assassinate do %>
        <div class="assassination-choice">
          <h3>Choose who to assassinate:</h3>
          <%= for player_id <- @game_state.player_order do %>
            <%= unless @game_state.role == Map.get(@game_state.visible_roles, player_id) do %>
              <button phx-click="assassinate" phx-value-target={player_id}>
                <%= @game_state.players[player_id].name %>
              </button>
            <% end %>
          <% end %>
        </div>
      <% else %>
        <p>The Assassin is choosing their target...</p>
      <% end %>
    </div>
    """
  end

  defp render_game_phase(%{game_state: %{phase: :game_over}} = assigns) do
    ~H"""
    <div class="game-over">
      <h2>Game Over!</h2>

      <div class="winner">
        <%= if @game_state.game_winner == :good do %>
          <h3>Good Wins!</h3>
        <% else %>
          <h3>Evil Wins!</h3>
        <% end %>
      </div>

      <%= render_quest_status(assigns) %>

      <div class="role-reveals">
        <h3>Roles:</h3>
        <%= for {player_id, role} <- @game_state.visible_roles do %>
          <div class="role-reveal">
            <%= @game_state.players[player_id].name %>: <%= role %>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp render_role_info(assigns) do
    ~H"""
    <div class="role-info">
      <div class="your-role">
        Your role: <span class={"role-#{@game_state.role}"}><%= @game_state.role %></span>
      </div>

      <%= if @game_state.visible_roles != [] do %>
        <div class="known-roles">
          <h4>You know:</h4>
          <%= for {player_id, role} <- @game_state.visible_roles do %>
            <div class="known-role">
              <%= @game_state.players[player_id].name %>: <%= role %>
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  defp render_quest_status(assigns) do
    ~H"""
    <div class="quest-status">
      <h3>Quest Progress:</h3>
      <div class="quest-results">
        <%= for {result, index} <- Enum.with_index(@game_state.quest_results, 1) do %>
          <div class={"quest-result quest-#{result}"}>
            Quest <%= index %>: <%= result %>
          </div>
        <% end %>

        <%= for missing <- (@game_state.current_quest..5) do %>
          <div class="quest-result quest-pending">
            Quest <%= missing %>: pending
          </div>
        <% end %>
      </div>

      <%= if @game_state.failed_votes > 0 do %>
        <div class="failed-votes">
          Failed votes: <%= @game_state.failed_votes %>/5
        </div>
      <% end %>
    </div>
    """
  end

  defp render_timer(assigns) do
    assigns = assign(assigns, :time_remaining, calculate_time_remaining(assigns.game_state, assigns.current_time))

    ~H"""
    <div class="timer">
      <%= if @time_remaining do %>
        <div class={"timer-display #{if @time_remaining < 30000, do: "timer-urgent", else: "timer-normal"}"}>
          Time remaining: <%= format_time(@time_remaining) %>
        </div>
        <%= if @time_remaining < 10000 do %>
          <div class="timer-warning">Hurry up!</div>
        <% end %>
      <% end %>
    </div>
    """
  end

  defp calculate_time_remaining(game_state, _current_time) do
    case game_state.time_remaining do
      nil -> nil
      time_remaining when time_remaining > 0 -> time_remaining
      _ -> 0
    end
  end

  defp format_time(milliseconds) when milliseconds <= 0, do: "0:00"
  defp format_time(milliseconds) do
    total_seconds = div(milliseconds, 1000)
    minutes = div(total_seconds, 60)
    seconds = rem(total_seconds, 60)

    "#{minutes}:#{String.pad_leading(Integer.to_string(seconds), 2, "0")}"
  end

  defp get_required_team_size(game_state) do
    player_count = length(game_state.player_order)
    quest_sizes = case player_count do
      5 -> [2, 3, 2, 3, 3]
      6 -> [2, 3, 4, 3, 4]
      7 -> [2, 3, 3, 4, 4]
      8 -> [3, 4, 4, 5, 5]
      9 -> [3, 4, 4, 5, 5]
      10 -> [3, 4, 4, 5, 5]
    end

    Enum.at(quest_sizes, game_state.current_quest - 1)
  end

  # Add some basic CSS styling
  defp render_styles(assigns) do
    ~H"""
    <style>
      .avalon-game {
        font-family: Arial, sans-serif;
        max-width: 800px;
        margin: 0 auto;
        padding: 20px;
      }

      .timer {
        background: #f0f0f0;
        padding: 10px;
        border-radius: 5px;
        margin-bottom: 20px;
        text-align: center;
      }

      .timer-display {
        font-size: 24px;
        font-weight: bold;
      }

      .timer-normal {
        color: #333;
      }

      .timer-urgent {
        color: #ff0000;
        animation: pulse 1s infinite;
      }

      .timer-warning {
        color: #ff6600;
        font-weight: bold;
        margin-top: 5px;
      }

      @keyframes pulse {
        0% { opacity: 1; }
        50% { opacity: 0.5; }
        100% { opacity: 1; }
      }

      .role-info {
        background: #e8f4f8;
        padding: 15px;
        border-radius: 5px;
        margin-bottom: 20px;
      }

      .role-merlin { color: #4169E1; font-weight: bold; }
      .role-assassin { color: #DC143C; font-weight: bold; }
      .role-evil { color: #8B0000; font-weight: bold; }
      .role-good { color: #228B22; font-weight: bold; }

      .quest-results {
        display: flex;
        gap: 10px;
        margin: 10px 0;
      }

      .quest-result {
        padding: 5px 10px;
        border-radius: 3px;
        font-weight: bold;
      }

      .quest-success { background: #90EE90; color: #006400; }
      .quest-fail { background: #FFB6C1; color: #8B0000; }
      .quest-pending { background: #D3D3D3; color: #696969; }

      .vote-buttons button, .quest-cards button {
        padding: 10px 20px;
        margin: 5px;
        border: none;
        border-radius: 5px;
        font-size: 16px;
        cursor: pointer;
      }

      .vote-buttons button:first-child {
        background: #90EE90;
        color: #006400;
      }

      .vote-buttons button:last-child {
        background: #FFB6C1;
        color: #8B0000;
      }

      .team-selection input[type="checkbox"] {
        margin-right: 10px;
      }

      .player-option {
        margin: 5px 0;
      }

      .error {
        color: #ff0000;
        font-weight: bold;
        padding: 10px;
        background: #ffe6e6;
        border-radius: 5px;
        margin: 10px 0;
      }

      .game-header {
        display: flex;
        justify-content: space-between;
        align-items: center;
        margin-bottom: 20px;
        padding-bottom: 10px;
        border-bottom: 2px solid #ddd;
      }

      .leave-game-btn {
        background: #ff6b6b;
        color: white;
        border: none;
        padding: 8px 16px;
        border-radius: 5px;
        cursor: pointer;
        font-size: 14px;
      }

      .leave-game-btn:hover {
        background: #ff5252;
      }

      .clear-session-btn {
        background: #6c757d;
        color: white;
        border: none;
        padding: 8px 16px;
        border-radius: 5px;
        cursor: pointer;
        font-size: 14px;
        margin-top: 10px;
        width: 100%;
      }

      .clear-session-btn:hover {
        background: #5a6268;
      }

      .reconnected-badge {
        background: #28a745;
        color: white;
        font-size: 12px;
        padding: 2px 6px;
        border-radius: 3px;
        margin-left: 8px;
      }
    </style>
    """
  end

  # Cookie management functions
  defp set_session_cookies(socket, game_id, player_id, player_name) do
    socket
    |> push_event("set_cookies", %{
      game_id: game_id,
      player_id: player_id,
      player_name: player_name
    })
  end

  defp clear_session_cookies(socket) do
    socket
    |> push_event("clear_cookies", %{})
  end
end
