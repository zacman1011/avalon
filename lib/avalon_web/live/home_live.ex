defmodule AvalonWeb.HomeLive do
  use AvalonWeb, :live_view

  def mount(_params, _session, socket) do
    {:ok, assign(socket, :game_id, nil)}
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
          <h3>Join Existing Game</h3>
          <form phx-submit="join_game">
            <input type="text" name="game_id" placeholder="Enter Game ID" required style="padding: 8px; width: 200px;" />
            <button type="submit" style="padding: 8px 16px; margin-left: 10px;">Join</button>
          </form>
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
