defmodule AvalonWeb.HomeLive do
  use AvalonWeb, :live_view

  def mount(_params, _session, socket) do
    {:ok, assign(socket, :game_id, nil)}
  end

  def handle_event("add_bots", %{"game_id" => game_id, "bot_count" => bot_count}, socket) do
    count = String.to_integer(bot_count)
    if count > 0 and count <= 10 do
      bot_names = Avalon.BotManager.add_bots(game_id, count)
      if length(bot_names) > 0 do
        {:noreply, put_flash(socket, :info, "Added #{length(bot_names)} bots: #{Enum.join(bot_names, ", ")}")}
      else
        {:noreply, put_flash(socket, :error, "Failed to add bots")}
      end
    else
      {:noreply, put_flash(socket, :error, "Invalid bot count")}
    end
  end

  def handle_event("fill_game", %{"game_id" => game_id, "target_count" => target_count}, socket) do
    count = String.to_integer(target_count)
    if count >= 5 and count <= 10 do
      bots_added = Avalon.BotManager.fill_game_to_count(game_id, count)
      if bots_added > 0 do
        {:noreply, put_flash(socket, :info, "Added #{bots_added} bots to fill the game")}
      else
        {:noreply, put_flash(socket, :info, "No bots needed or game not found")}
      end
    else
      {:noreply, put_flash(socket, :error, "Invalid target count")}
    end
  end

  def handle_event("quick_start_with_bots", %{"player_count" => player_count}, socket) do
    count = String.to_integer(player_count)
    if count >= 5 and count <= 10 do
      # Create a new game
      game_id = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
      Avalon.GameSupervisor.start_game(game_id)

      # Add bots to fill the game
      bots_added = Avalon.BotManager.fill_game_to_count(game_id, count)

      {:noreply,
       put_flash(socket, :info, "Created game #{game_id} with #{bots_added} bots")
       |> push_navigate(to: ~p"/game/#{game_id}")}
    else
      {:noreply, put_flash(socket, :error, "Invalid player count")}
    end
  end

  def handle_event("create_game", _, socket) do
    game_id = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

    # Start the game process
    Avalon.GameSupervisor.start_game(game_id)

    {:noreply, push_navigate(socket, to: ~p"/game/#{game_id}")}
  end

  def handle_event("join_game", %{"game_id" => game_id}, socket) do
    # Simple validation - in real app you'd check if game exists
    if String.length(game_id) > 0 do
      {:noreply, push_navigate(socket, to: ~p"/game/#{game_id}")}
    else
      {:noreply, socket}
    end
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div style="max-width: 400px; margin: 50px auto; padding: 20px; font-family: Arial;">
        <h1>The Resistance: Avalon</h1>

        <div style="margin: 30px 0;">
          <h3>Create New Game</h3>
          <button phx-click="create_game" style="padding: 10px 20px; font-size: 16px;">
            Create Game
          </button>
        </div>

        <div style="margin: 30px 0;">
          <h3>Quick Start with Bots</h3>
          <form phx-submit="quick_start_with_bots">
            <select name="player_count" style="padding: 8px; margin-right: 10px;">
              <option value="5">5 Players</option>
              <option value="6">6 Players</option>
              <option value="7">7 Players</option>
              <option value="8">8 Players</option>
              <option value="9">9 Players</option>
              <option value="10">10 Players</option>
            </select>
            <button type="submit" style="padding: 10px 20px; font-size: 16px;">
              Start Game with Bots
            </button>
          </form>
        </div>

        <div style="margin: 30px 0;">
          <h3>Join Existing Game</h3>
          <form phx-submit="join_game">
            <input type="text" name="game_id" placeholder="Enter Game ID" required style="padding: 8px; width: 200px;" />
            <button type="submit" style="padding: 8px 16px; margin-left: 10px;">Join</button>
          </form>
        </div>

        <div style="margin: 30px 0;">
          <h3>Bot Management</h3>
          <div style="margin: 15px 0;">
            <h4>Add Bots to Game</h4>
            <form phx-submit="add_bots">
              <input type="text" name="game_id" placeholder="Game ID" required style="padding: 8px; width: 150px;" />
              <select name="bot_count" style="padding: 8px; margin-left: 5px;">
                <option value="1">1 Bot</option>
                <option value="2">2 Bots</option>
                <option value="3">3 Bots</option>
                <option value="4">4 Bots</option>
                <option value="5">5 Bots</option>
              </select>
              <button type="submit" style="padding: 8px 16px; margin-left: 10px;">Add Bots</button>
            </form>
          </div>

          <div style="margin: 15px 0;">
            <h4>Fill Game to Player Count</h4>
            <form phx-submit="fill_game">
              <input type="text" name="game_id" placeholder="Game ID" required style="padding: 8px; width: 150px;" />
              <select name="target_count" style="padding: 8px; margin-left: 5px;">
                <option value="5">5 Players</option>
                <option value="6">6 Players</option>
                <option value="7">7 Players</option>
                <option value="8">8 Players</option>
                <option value="9">9 Players</option>
                <option value="10">10 Players</option>
              </select>
              <button type="submit" style="padding: 8px 16px; margin-left: 10px;">Fill Game</button>
            </form>
          </div>
        </div>

        <div style="margin-top: 40px; font-size: 14px; color: #666;">
          <h4>Game Rules Summary:</h4>
          <ul>
            <li>5-10 players total</li>
            <li>Good players try to complete 3 quests successfully</li>
            <li>Evil players try to sabotage quests or stay hidden</li>
            <li>Merlin knows who the evil players are but must stay hidden</li>
            <li>If good completes 3 quests, evil can win by assassinating Merlin</li>
            <li>In 7+ player games: Lady of the Lake allows investigation after quests 2 & 3</li>
          </ul>

          <h4>Timing Rules:</h4>
          <ul>
            <li>Team building: 10 minutes (auto-pass to next leader)</li>
            <li>Voting: 1 minute (auto-approve for non-voters)</li>
            <li>Quest cards: 30 seconds (auto-play based on role)</li>
            <li>Assassination: 2 minutes (random target if no choice)</li>
          </ul>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
