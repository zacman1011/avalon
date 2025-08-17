defmodule Avalon.GameLogicTest do
  use ExUnit.Case
  alias Avalon.GameLogic

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
      leader = GameLogic.get_current_leader(state)
      non_leader = Enum.find(state.player_order, fn id -> id != leader end)
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

  describe "timing and late submission tests" do
    test "rejects team proposal in wrong phase" do
      state = setup_game_with_players(5)
      leader = GameLogic.get_current_leader(state)
      team_members = [leader, Enum.at(state.player_order, 1)]

      # Try to propose team in voting phase
      state = %{state | phase: :voting}
      {:error, reason} = GameLogic.propose_team(state, leader, team_members)
      assert reason == "Not your turn or wrong phase"

      # Try to propose team in quest phase
      state = %{state | phase: :quest}
      {:error, reason} = GameLogic.propose_team(state, leader, team_members)
      assert reason == "Not your turn or wrong phase"

      # Try to propose team in assassination phase
      state = %{state | phase: :assassination}
      {:error, reason} = GameLogic.propose_team(state, leader, team_members)
      assert reason == "Not your turn or wrong phase"
    end

    test "rejects votes in wrong phase" do
      state = setup_game_with_players(5)
      player = List.first(state.player_order)

      # Try to vote in team building phase
      state = %{state | phase: :team_building}
      {:error, reason} = GameLogic.vote_on_team(state, player, :approve)
      assert reason == "Cannot vote"

      # Try to vote in quest phase
      state = %{state | phase: :quest}
      {:error, reason} = GameLogic.vote_on_team(state, player, :approve)
      assert reason == "Cannot vote"

      # Try to vote in assassination phase
      state = %{state | phase: :assassination}
      {:error, reason} = GameLogic.vote_on_team(state, player, :approve)
      assert reason == "Cannot vote"
    end

    test "rejects quest cards in wrong phase" do
      state = setup_game_with_players(5)
      player = List.first(state.player_order)

      # Try to play quest card in team building phase
      state = %{state | phase: :team_building}
      {:error, reason} = GameLogic.play_quest_card(state, player, :success)
      assert reason == "Cannot play quest card"

      # Try to play quest card in voting phase
      state = %{state | phase: :voting}
      {:error, reason} = GameLogic.play_quest_card(state, player, :success)
      assert reason == "Cannot play quest card"

      # Try to play quest card in assassination phase
      state = %{state | phase: :assassination}
      {:error, reason} = GameLogic.play_quest_card(state, player, :success)
      assert reason == "Cannot play quest card"
    end

    test "rejects quest cards from players not on team" do
      state = setup_game_with_players(5)
      state = %{state | phase: :quest, proposed_team: [List.first(state.player_order)]}

      # Try to play quest card from player not on team
      player_not_on_team = Enum.at(state.player_order, 1)
      {:error, reason} = GameLogic.play_quest_card(state, player_not_on_team, :success)
      assert reason == "Cannot play quest card"
    end

    test "rejects assassination in wrong phase" do
      state = setup_game_with_players(5)
      target = List.first(state.player_order)

      # Try to assassinate in team building phase
      state = %{state | phase: :team_building}
      {:error, reason} = GameLogic.assassinate(state, target)
      assert reason == "Cannot assassinate now"

      # Try to assassinate in voting phase
      state = %{state | phase: :voting}
      {:error, reason} = GameLogic.assassinate(state, target)
      assert reason == "Cannot assassinate now"

      # Try to assassinate in quest phase
      state = %{state | phase: :quest}
      {:error, reason} = GameLogic.assassinate(state, target)
      assert reason == "Cannot assassinate now"
    end

    test "rejects Lady of the Lake use in wrong phase" do
      state = setup_game_with_players(5)
      holder = state.lady_of_the_lake.holder
      target = Enum.find(state.player_order, fn id -> id != holder end)

      # Try to use Lady of the Lake in team building phase
      state = %{state | phase: :team_building}
      {:error, reason} = GameLogic.use_lady_of_the_lake(state, holder, target)
      assert reason == "Cannot use Lady of the Lake"

      # Try to use Lady of the Lake in voting phase
      state = %{state | phase: :voting}
      {:error, reason} = GameLogic.use_lady_of_the_lake(state, holder, target)
      assert reason == "Cannot use Lady of the Lake"

      # Try to use Lady of the Lake in quest phase
      state = %{state | phase: :quest}
      {:error, reason} = GameLogic.use_lady_of_the_lake(state, holder, target)
      assert reason == "Cannot use Lady of the Lake"
    end

    test "rejects Lady of the Lake use from non-holder" do
      state = setup_game_with_players(5)
      holder = state.lady_of_the_lake.holder
      non_holder = Enum.find(state.player_order, fn id -> id != holder end)
      target = Enum.find(state.player_order, fn id -> id != holder and id != non_holder end)

      state = %{state | phase: :lady_of_the_lake}
      {:error, reason} = GameLogic.use_lady_of_the_lake(state, non_holder, target)
      assert reason == "Cannot use Lady of the Lake"
    end
  end

  describe "timeout handling tests" do
    test "team building timeout moves to next leader" do
      state = setup_game_with_players(5)
      original_leader = GameLogic.get_current_leader(state)

      new_state = GameLogic.handle_team_building_timeout(state)

      assert new_state.phase == :team_building
      assert new_state.failed_votes == 1
      assert GameLogic.get_current_leader(new_state) != original_leader
      assert new_state.proposed_team == []
    end

    test "team building timeout with 5 failed votes ends game" do
      state = setup_game_with_players(5)
      state = %{state | failed_votes: 4} # One more failure will end the game

      new_state = GameLogic.handle_team_building_timeout(state)

      assert new_state.phase == :game_over
      assert new_state.game_winner == :evil
      assert new_state.failed_votes == 5
    end

    test "voting timeout auto-approves missing votes" do
      state = setup_game_with_players(5)
      state = %{state | phase: :voting, proposed_team: state.player_order}

      # Only first player voted
      state = %{state | votes: %{List.first(state.player_order) => :approve}}

      new_state = GameLogic.handle_voting_timeout(state)

      # Should auto-approve the remaining 4 votes, making it 5 approve vs 0 reject
      assert new_state.phase == :quest
      assert map_size(new_state.votes) == 5
      assert Enum.all?(new_state.votes, fn {_, vote} -> vote == :approve end)
    end

    test "voting timeout with team rejection moves to next leader" do
      state = setup_game_with_players(5)
      state = %{state | phase: :voting, proposed_team: state.player_order}

      # First 3 players vote reject, others will be auto-approved
      state = %{state | votes: %{
        List.first(state.player_order) => :reject,
        Enum.at(state.player_order, 1) => :reject,
        Enum.at(state.player_order, 2) => :reject
      }}

      new_state = GameLogic.handle_voting_timeout(state)

      # Should auto-approve the remaining 2 votes, making it 2 approve vs 3 reject
      # Since 2 <= 2.5, team is rejected and moves to next leader
      assert new_state.phase == :team_building
      assert new_state.failed_votes == 1
    end

    test "voting timeout with 5 failed votes ends game" do
      state = setup_game_with_players(5)
      state = %{state | phase: :voting, proposed_team: state.player_order, failed_votes: 4}

      # All players vote reject to ensure team rejection
      state = Enum.reduce(state.player_order, state, fn player_id, acc ->
        %{acc | votes: Map.put(acc.votes, player_id, :reject)}
      end)

      new_state = GameLogic.handle_voting_timeout(state)

      # All players rejected, so team is rejected, making it 5 failed votes total
      assert new_state.phase == :game_over
      assert new_state.game_winner == :evil
      assert new_state.failed_votes == 5
    end

    test "quest timeout auto-plays missing cards" do
      state = setup_game_with_players(5)
      state = %{state | phase: :quest, proposed_team: state.player_order}

      # Only first player played a card
      state = %{state | quest_cards: [:success]}

      new_state = GameLogic.handle_quest_timeout(state)

      # Should auto-play cards for the remaining 4 players
      assert length(new_state.quest_cards) == 5
      assert length(new_state.quest_results) == 1
    end

    test "quest timeout with 3 successes moves to assassination" do
      state = setup_game_with_players(5)
      state = %{state | phase: :quest, proposed_team: state.player_order, quest_results: [:success, :success]}

      # Only first player played a card
      state = %{state | quest_cards: [:success]}

      new_state = GameLogic.handle_quest_timeout(state)

      # Should auto-play cards and resolve quest, making it 3 successes total
      assert new_state.phase == :assassination
      assert length(new_state.quest_results) == 3
    end

    test "quest timeout with 3 failures ends game" do
      state = setup_game_with_players(5)
      state = %{state | phase: :quest, proposed_team: state.player_order, quest_results: [:fail, :fail]}

      # Only first player played a card
      state = %{state | quest_cards: [:fail]}

      new_state = GameLogic.handle_quest_timeout(state)

      # Should auto-play cards and resolve quest, making it 3 failures total
      assert new_state.phase == :game_over
      assert new_state.game_winner == :evil
      assert length(new_state.quest_results) == 3
    end

    test "assassination timeout picks random target" do
      state = setup_game_with_players(5)
      state = %{state | phase: :assassination}

      new_state = GameLogic.handle_assassination_timeout(state)

      assert new_state.phase == :game_over
      assert new_state.game_winner in [:good, :evil]
    end

    test "Lady of the Lake timeout auto-uses on valid target" do
      state = setup_game_with_players(5)
      holder = state.lady_of_the_lake.holder

      new_state = GameLogic.handle_lady_of_the_lake_timeout(state)

      # Should auto-use Lady of the Lake on a valid target
      assert new_state.phase == :lady_reveal
      assert new_state.lady_of_the_lake.holder != holder
      assert new_state.lady_of_the_lake.pending_reveal != nil
    end

    test "Lady of the Lake timeout with no valid targets continues to next quest" do
      state = setup_game_with_players(5)
      holder = state.lady_of_the_lake.holder

      # Mark all other players as used
      used_targets = Enum.filter(state.player_order, fn id -> id != holder end)
      state = %{state | lady_of_the_lake: %{state.lady_of_the_lake | used_targets: used_targets}}

      new_state = GameLogic.handle_lady_of_the_lake_timeout(state)

      # Should continue to next quest since no valid targets
      assert new_state.phase == :team_building
      assert new_state.current_quest == 2
    end
  end

  describe "edge cases and error conditions" do
    test "rejects vote from non-existent player" do
      state = setup_game_with_players(5)
      state = %{state | phase: :voting, proposed_team: state.player_order}

      {:error, reason} = GameLogic.vote_on_team(state, "non-existent-player", :approve)
      assert reason == "Cannot vote"
    end

    test "rejects quest card from non-existent player" do
      state = setup_game_with_players(5)
      state = %{state | phase: :quest, proposed_team: state.player_order}

      {:error, reason} = GameLogic.play_quest_card(state, "non-existent-player", :success)
      assert reason == "Cannot play quest card"
    end

    test "handles empty proposed team gracefully" do
      state = setup_game_with_players(5)
      state = %{state | phase: :quest, proposed_team: []}

      # Should not crash when no one is on the team
      {:error, reason} = GameLogic.play_quest_card(state, List.first(state.player_order), :success)
      assert reason == "Cannot play quest card"
    end

    test "handles quest with all success cards" do
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

    test "handles quest with all fail cards" do
      state = setup_game_with_players(5)
      state = %{state | phase: :quest, proposed_team: state.player_order}

      # All players play fail
      state = Enum.reduce(state.player_order, state, fn player_id, acc ->
        {:ok, new_state} = GameLogic.play_quest_card(acc, player_id, :fail)
        new_state
      end)

      assert state.phase == :team_building
      assert length(state.quest_results) == 1
      assert List.first(state.quest_results) == :fail
    end

    test "handles mixed success/fail quest cards" do
      state = setup_game_with_players(5)
      state = %{state | phase: :quest, proposed_team: state.player_order}

      # First 3 players play success, last 2 play fail
      players = state.player_order
      state = GameLogic.play_quest_card(state, Enum.at(players, 0), :success) |> elem(1)
      state = GameLogic.play_quest_card(state, Enum.at(players, 1), :success) |> elem(1)
      state = GameLogic.play_quest_card(state, Enum.at(players, 2), :success) |> elem(1)
      state = GameLogic.play_quest_card(state, Enum.at(players, 3), :fail) |> elem(1)
      {:ok, state} = GameLogic.play_quest_card(state, Enum.at(players, 4), :fail)

      assert state.phase == :team_building
      assert length(state.quest_results) == 1
      assert List.first(state.quest_results) == :fail # 2 fails vs 3 successes, but 2 fails needed for 5-player quest 1
    end

    test "handles 7+ player game with 2 fails needed for 4th quest" do
      state = setup_game_with_players(7)
      state = %{state | current_quest: 4, phase: :quest, proposed_team: state.player_order}

      # First 5 players play success, last 2 play fail
      players = state.player_order
      state = GameLogic.play_quest_card(state, Enum.at(players, 0), :success) |> elem(1)
      state = GameLogic.play_quest_card(state, Enum.at(players, 1), :success) |> elem(1)
      state = GameLogic.play_quest_card(state, Enum.at(players, 2), :success) |> elem(1)
      state = GameLogic.play_quest_card(state, Enum.at(players, 3), :success) |> elem(1)
      state = GameLogic.play_quest_card(state, Enum.at(players, 4), :success) |> elem(1)
      state = GameLogic.play_quest_card(state, Enum.at(players, 5), :fail) |> elem(1)
      {:ok, state} = GameLogic.play_quest_card(state, Enum.at(players, 6), :fail)

      assert state.phase == :team_building
      assert length(state.quest_results) == 1
      assert List.first(state.quest_results) == :fail # 2 fails needed for 7+ player quest 4
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
