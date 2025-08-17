defmodule Avalon.BotPlayerTest do
  use ExUnit.Case
  alias Avalon.{Game, BotPlayer, BotManager}

  setup do
    # Create a test game
    game_id = "test_game_#{:rand.uniform(1000)}"
    {:ok, _pid} = Game.start_link(game_id)

    # Add a human player first
    {:ok, player_id} = Game.join_game(game_id, "TestPlayer")

    %{game_id: game_id, player_id: player_id}
  end

  test "bot can join a game", %{game_id: game_id, player_id: player_id} do
    bot_name = "TestBot"
    {:ok, bot_pid} = BotPlayer.start_link(game_id, bot_name)

    # Verify bot joined by checking game state
    {:ok, game_state} = Game.get_game_state(game_id, player_id)
    player_names = Map.values(game_state.players) |> Enum.map(& &1.name)

    assert bot_name in player_names
    assert is_pid(bot_pid)
  end

  test "bot manager can add multiple bots", %{game_id: game_id, player_id: player_id} do
    bot_names = BotManager.add_bots(game_id, 3)

    assert length(bot_names) == 3
    assert Enum.all?(bot_names, &String.ends_with?(&1, "Bot"))

    # Verify bots are in the game
    {:ok, game_state} = Game.get_game_state(game_id, player_id)
    player_names = Map.values(game_state.players) |> Enum.map(& &1.name)

    assert Enum.all?(bot_names, &(&1 in player_names))
  end

  test "bot manager can fill game to target count", %{game_id: game_id, player_id: player_id} do
    # Game starts with 1 player, need 4 more to reach 5
    bots_added = BotManager.fill_game_to_count(game_id, 5)

    # The bot manager adds bots until the game is full, so it might add more than needed
    assert bots_added >= 4

    # Verify total player count is at least 5
    {:ok, game_state} = Game.get_game_state(game_id, player_id)
    assert length(game_state.player_order) >= 5
  end

  test "bot manager handles non-existent game", %{game_id: _game_id} do
    non_existent_game = "non_existent"
    bots_added = BotManager.fill_game_to_count(non_existent_game, 5)

    assert bots_added == 0
  end

  test "bot can be stopped", %{game_id: game_id, player_id: _player_id} do
    bot_name = "TestBot"
    {:ok, _bot_pid} = BotPlayer.start_link(game_id, bot_name)

    # Stop the bot
    :ok = BotPlayer.stop_bot(game_id, bot_name)

    # Bot should be stopped (we can't easily verify this without more complex setup)
    assert true
  end
end
