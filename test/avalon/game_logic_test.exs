defmodule Avalon.GameLogicTest do
  use ExUnit.Case
  alias Avalon.GameLogic
  alias Avalon.Game.GameState

  describe "new_game/1" do
    test "creates a new game state" do
      game_id = "test-game-123"
      state = GameLogic.new_game(game_id)

      assert state.id == game_id
      assert state.phase == :lobby
      assert state.current_quest == 1
      assert state.players == %{}
      assert state.player_order == []
      assert state.roles == %{}
      assert state.game_winner == nil
    end
  end

  describe "join_game/2" do
    test "adds a player to the game" do
      state = GameLogic.new_game("test-game")
      {:ok, player_id, new_state} = GameLogic.join_game(state, "Alice")

      assert player_id != nil
      assert new_state.players[player_id].name == "Alice"
      assert new_state.player_order == [player_id]
    end

    test "returns error when game is full" do
      state = GameLogic.new_game("test-game")

      # Add 10 players
      state = Enum.reduce(1..10, state, fn i, acc ->
        {:ok, _player_id, new_state} = GameLogic.join_game(acc, "Player#{i}")
        new_state
      end)

      {:error, reason} = GameLogic.join_game(state, "ExtraPlayer")
      assert reason == "Game is full"
    end
  end

  describe "start_game/1" do
    test "starts game with minimum players" do
      state = GameLogic.new_game("test-game")

      # Add 5 players
      state = Enum.reduce(1..5, state, fn i, acc ->
        {:ok, _player_id, new_state} = GameLogic.join_game(acc, "Player#{i}")
        new_state
      end)

      {:ok, new_state} = GameLogic.start_game(state)

      assert new_state.phase == :team_building
      assert map_size(new_state.roles) == 5
      assert new_state.lady_of_the_lake.holder != nil
    end

    test "returns error with insufficient players" do
      state = GameLogic.new_game("test-game")

      # Add only 4 players
      state = Enum.reduce(1..4, state, fn i, acc ->
        {:ok, _player_id, new_state} = GameLogic.join_game(acc, "Player#{i}")
        new_state
      end)

      {:error, reason} = GameLogic.start_game(state)
      assert reason == "Need at least 5 players"
    end
  end

  describe "propose_team/3" do
    test "allows current leader to propose team" do
      state = setup_game_with_players(5)
      leader = GameLogic.get_current_leader(state)
      team_members = [leader, Enum.at(state.player_order, 1)]

      {:ok, new_state} = GameLogic.propose_team(state, leader, team_members)

      assert new_state.phase == :voting
      assert new_state.proposed_team == team_members
      assert new_state.votes == %{}
    end

    test "rejects team proposal from non-leader" do
      state = setup_game_with_players(5)
      non_leader = Enum.at(state.player_order, 1)
      team_members = [non_leader, Enum.at(state.player_order, 2)]

      {:error, reason} = GameLogic.propose_team(state, non_leader, team_members)
      assert reason == "Not your turn or wrong phase"
    end

    test "rejects team with wrong size" do
      state = setup_game_with_players(5)
      leader = GameLogic.get_current_leader(state)
      wrong_team = [leader] # Should be 2 players for quest 1

      {:error, reason} = GameLogic.propose_team(state, leader, wrong_team)
      assert reason == "Wrong team size"
    end
  end

  describe "vote_on_team/3" do
    test "records votes and transitions to quest when approved" do
      state = setup_game_with_players(5)
      state = %{state | phase: :voting, proposed_team: state.player_order}

      # All players approve
      state = Enum.reduce(state.player_order, state, fn player_id, acc ->
        {:ok, new_state} = GameLogic.vote_on_team(acc, player_id, :approve)
        new_state
      end)

      assert state.phase == :quest
      assert state.failed_votes == 0
    end

    test "transitions to next leader when team rejected" do
      state = setup_game_with_players(5)
      state = %{state | phase: :voting, proposed_team: state.player_order}

      # All players reject
      state = Enum.reduce(state.player_order, state, fn player_id, acc ->
        {:ok, new_state} = GameLogic.vote_on_team(acc, player_id, :reject)
        new_state
      end)

      assert state.phase == :team_building
      assert state.failed_votes == 1
    end
  end

  describe "play_quest_card/3" do
    test "records quest cards and resolves quest" do
      state = setup_game_with_players(5)
      state = %{state | phase: :quest, proposed_team: state.player_order}

      # All players play success
      state = Enum.reduce(state.player_order, state, fn player_id, acc ->
        {:ok, new_state} = GameLogic.play_quest_card(acc, player_id, :success)
        new_state
      end)

      assert state.phase == :team_building
      assert length(state.quest_results) == 1
      assert List.first(state.quest_results) == :success
    end
  end

  describe "assassinate/2" do
    test "evil wins when assassinating Merlin" do
      state = setup_game_with_players(5)
      state = %{state | phase: :assassination}

      merlin_id = GameLogic.get_merlin_id(state.roles)
      {:ok, new_state} = GameLogic.assassinate(state, merlin_id)

      assert new_state.game_winner == :evil
      assert new_state.phase == :game_over
    end

    test "good wins when assassinating non-Merlin" do
      state = setup_game_with_players(5)
      state = %{state | phase: :assassination}

      # Find a non-Merlin player
      merlin_id = GameLogic.get_merlin_id(state.roles)
      non_merlin = Enum.find(state.player_order, fn id -> id != merlin_id end)

      {:ok, new_state} = GameLogic.assassinate(state, non_merlin)

      assert new_state.game_winner == :good
      assert new_state.phase == :game_over
    end
  end

  describe "helper functions" do
    test "get_role_distribution/1" do
      assert GameLogic.get_role_distribution(5) == {3, 2}
      assert GameLogic.get_role_distribution(6) == {4, 2}
      assert GameLogic.get_role_distribution(7) == {4, 3}
      assert GameLogic.get_role_distribution(8) == {5, 3}
      assert GameLogic.get_role_distribution(9) == {6, 3}
      assert GameLogic.get_role_distribution(10) == {6, 4}
    end

    test "get_quest_size/2" do
      assert GameLogic.get_quest_size(5, 1) == 2
      assert GameLogic.get_quest_size(5, 2) == 3
      assert GameLogic.get_quest_size(5, 3) == 2
      assert GameLogic.get_quest_size(5, 4) == 3
      assert GameLogic.get_quest_size(5, 5) == 3
    end

    test "resolve_quest/3" do
      # Normal quest - 1 fail needed
      assert GameLogic.resolve_quest([:success, :success], 5, 1) == :success
      assert GameLogic.resolve_quest([:success, :fail], 5, 1) == :fail

      # 4th quest in 7+ player game - 2 fails needed
      assert GameLogic.resolve_quest([:success, :success, :success], 7, 4) == :success
      assert GameLogic.resolve_quest([:success, :fail, :success], 7, 4) == :success
      assert GameLogic.resolve_quest([:success, :fail, :fail], 7, 4) == :fail
    end
  end

  # Helper function to set up a game with the specified number of players
  defp setup_game_with_players(count) do
    state = GameLogic.new_game("test-game")

    # Add players
    state = Enum.reduce(1..count, state, fn i, acc ->
      {:ok, _player_id, new_state} = GameLogic.join_game(acc, "Player#{i}")
      new_state
    end)

    # Start the game
    {:ok, state} = GameLogic.start_game(state)
    state
  end
end
