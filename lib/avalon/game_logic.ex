defmodule Avalon.GameLogic do
  @moduledoc """
  Pure game logic functions for Avalon. These functions take game state and parameters
  and return new game state, making them easily testable without GenServer dependencies.
  """

  alias Avalon.Game.GameState

  @type vote :: :approve | :reject
  @type quest_card :: :success | :fail
  @type quest_result :: :success | :fail
  @type game_winner :: :good | :evil

  # Game State Management

  @doc """
  Creates a new game state with the given game ID.
  """
  @spec new_game(String.t()) :: GameState.t()
  def new_game(game_id) do
    %GameState{
      id: game_id,
      players: %{},
      player_order: [],
      roles: %{},
      phase: :lobby,
      current_quest: 1,
      quest_results: [],
      current_leader_index: 0,
      proposed_team: [],
      votes: %{},
      failed_votes: 0,
      quest_cards: [],
      game_winner: nil,
      lady_of_the_lake: %{
        holder: nil,
        used_targets: [],
        pending_reveal: nil
      }
    }
  end

  @doc """
  Adds a player to the game. Returns {:ok, player_id, new_state} or {:error, reason}.
  """
  @spec join_game(GameState.t(), String.t()) :: {:ok, String.t(), GameState.t()} | {:error, String.t()}
  def join_game(state, player_name) do
    if length(state.player_order) >= 10 do
      {:error, "Game is full"}
    else
      player_id = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
      player = %{id: player_id, name: player_name}

      new_state = %{state |
        players: Map.put(state.players, player_id, player),
        player_order: state.player_order ++ [player_id]
      }

      {:ok, player_id, new_state}
    end
  end

  @doc """
  Starts the game by assigning roles and transitioning to team building phase.
  Returns {:ok, new_state} or {:error, reason}.
  """
  @spec start_game(GameState.t()) :: {:ok, GameState.t()} | {:error, String.t()}
  def start_game(state) do
    player_count = length(state.player_order)

    if player_count < 5 do
      {:error, "Need at least 5 players"}
    else
      # Assign roles based on player count
      {good_count, evil_count} = get_role_distribution(player_count)
      roles = assign_roles(state.player_order, good_count, evil_count)

      # Initialize Lady of the Lake (starts with player to the right of Merlin)
      merlin_id = get_merlin_id(roles)
      merlin_index = Enum.find_index(state.player_order, &(&1 == merlin_id))
      lady_holder_index = rem(merlin_index + 1, player_count)
      lady_holder = Enum.at(state.player_order, lady_holder_index)

      new_state = %{state |
        roles: roles,
        phase: :team_building,
        current_leader_index: :rand.uniform(player_count) - 1,
        lady_of_the_lake: %{
          holder: lady_holder,
          used_targets: [],
          pending_reveal: nil
        }
      }

      {:ok, new_state}
    end
  end

  # Team Building

  @doc """
  Proposes a team for the current quest. Returns {:ok, new_state} or {:error, reason}.
  """
  @spec propose_team(GameState.t(), String.t(), [String.t()]) :: {:ok, GameState.t()} | {:error, String.t()}
  def propose_team(state, player_id, team_members) do
    current_leader = Enum.at(state.player_order, state.current_leader_index)

    if player_id == current_leader and state.phase == :team_building do
      quest_size = get_quest_size(length(state.player_order), state.current_quest)

      if length(team_members) == quest_size do
        new_state = %{state |
          proposed_team: team_members,
          phase: :voting,
          votes: %{}
        }

        {:ok, new_state}
      else
        {:error, "Wrong team size"}
      end
    else
      {:error, "Not your turn or wrong phase"}
    end
  end

  # Voting

  @doc """
  Records a vote on the proposed team. Returns {:ok, new_state} or {:error, reason}.
  """
  @spec vote_on_team(GameState.t(), String.t(), vote()) :: {:ok, GameState.t()} | {:error, String.t()}
  def vote_on_team(state, player_id, vote) do
    if state.phase == :voting and Map.has_key?(state.players, player_id) do
      new_votes = Map.put(state.votes, player_id, vote)

      if map_size(new_votes) == length(state.player_order) do
        # All votes collected, resolve
        approve_count = new_votes |> Enum.count(fn {_, v} -> v == :approve end)
        team_approved = approve_count > length(state.player_order) / 2

        if team_approved do
          new_state = %{state |
            phase: :quest,
            votes: new_votes,
            quest_cards: [],
            failed_votes: 0
          }

          {:ok, new_state}
        else
          # Team rejected
          new_failed_votes = state.failed_votes + 1

          if new_failed_votes >= 5 do
            # Evil wins
            new_state = %{state | game_winner: :evil, phase: :game_over}
            {:ok, new_state}
          else
            # Next leader
            next_leader = rem(state.current_leader_index + 1, length(state.player_order))
            new_state = %{state |
              current_leader_index: next_leader,
              phase: :team_building,
              votes: new_votes,
              failed_votes: new_failed_votes,
              proposed_team: []
            }

            {:ok, new_state}
          end
        end
      else
        new_state = %{state | votes: new_votes}
        {:ok, new_state}
      end
    else
      {:error, "Cannot vote"}
    end
  end

  # Quest Resolution

  @doc """
  Plays a quest card. Returns {:ok, new_state} or {:error, reason}.
  """
  @spec play_quest_card(GameState.t(), String.t(), quest_card()) :: {:ok, GameState.t()} | {:error, String.t()}
  def play_quest_card(state, player_id, card) do
    if state.phase == :quest and player_id in state.proposed_team do
      new_quest_cards = [card | state.quest_cards]

      if length(new_quest_cards) == length(state.proposed_team) do
        # All quest cards submitted, resolve quest
        quest_result = resolve_quest(new_quest_cards, length(state.player_order), state.current_quest)
        new_quest_results = state.quest_results ++ [quest_result]

        # Check win conditions
        success_count = Enum.count(new_quest_results, & &1 == :success)
        fail_count = Enum.count(new_quest_results, & &1 == :fail)

        cond do
          success_count >= 3 ->
            # Good might win, but evil gets to assassinate Merlin
            new_state = %{state |
              phase: :assassination,
              quest_results: new_quest_results,
              quest_cards: new_quest_cards
            }

            {:ok, new_state}

          fail_count >= 3 ->
            # Evil wins
            new_state = %{state |
              game_winner: :evil,
              phase: :game_over,
              quest_results: new_quest_results,
              quest_cards: new_quest_cards
            }

            {:ok, new_state}

          true ->
            # Continue to next quest
            next_leader = rem(state.current_leader_index + 1, length(state.player_order))
            new_state = %{state |
              current_quest: state.current_quest + 1,
              phase: :team_building,
              current_leader_index: next_leader,
              quest_results: new_quest_results,
              proposed_team: [],
              votes: %{},
              quest_cards: new_quest_cards
            }

            {:ok, new_state}
        end
      else
        new_state = %{state | quest_cards: new_quest_cards}
        {:ok, new_state}
      end
    else
      {:error, "Cannot play quest card"}
    end
  end

  # Assassination

  @doc """
  Performs assassination attempt. Returns {:ok, new_state} or {:error, reason}.
  """
  @spec assassinate(GameState.t(), String.t()) :: {:ok, GameState.t()} | {:error, String.t()}
  def assassinate(state, target_player_id) do
    if state.phase == :assassination do
      merlin_id = get_merlin_id(state.roles)

      new_state = if target_player_id == merlin_id do
        # Evil wins by assassinating Merlin
        %{state | game_winner: :evil, phase: :game_over}
      else
        # Good wins
        %{state | game_winner: :good, phase: :game_over}
      end

      {:ok, new_state}
    else
      {:error, "Cannot assassinate now"}
    end
  end

  # Lady of the Lake

  @doc """
  Uses Lady of the Lake ability. Returns {:ok, new_state} or {:error, reason}.
  """
  @spec use_lady_of_the_lake(GameState.t(), String.t(), String.t()) :: {:ok, GameState.t()} | {:error, String.t()}
  def use_lady_of_the_lake(state, player_id, target_id) do
    if state.phase == :lady_of_the_lake and state.lady_of_the_lake.holder == player_id do
      target_role = Map.get(state.roles, target_id)
      target_team = if target_role in [:evil, :assassin], do: :evil, else: :good

      new_used_targets = [target_id | state.lady_of_the_lake.used_targets]

      new_state = %{state |
        lady_of_the_lake: %{
          holder: target_id,
          used_targets: new_used_targets,
          pending_reveal: %{target: target_id, team: target_team, revealer: player_id}
        },
        phase: :lady_reveal
      }

      {:ok, new_state}
    else
      {:error, "Cannot use Lady of the Lake"}
    end
  end

  @doc """
  Continues to next quest after Lady of the Lake reveal.
  """
  @spec continue_to_next_quest(GameState.t()) :: GameState.t()
  def continue_to_next_quest(state) do
    next_leader = rem(state.current_leader_index + 1, length(state.player_order))
    %{state |
      current_quest: state.current_quest + 1,
      phase: :team_building,
      current_leader_index: next_leader,
      proposed_team: [],
      votes: %{},
      lady_of_the_lake: Map.put(state.lady_of_the_lake, :pending_reveal, nil)
    }
  end

  # Timeout Handling

  @doc """
  Handles timeout for team building phase.
  """
  @spec handle_team_building_timeout(GameState.t()) :: GameState.t()
  def handle_team_building_timeout(state) do
    # Leader didn't propose in time, move to next leader
    next_leader = rem(state.current_leader_index + 1, length(state.player_order))
    new_failed_votes = state.failed_votes + 1

    if new_failed_votes >= 5 do
      # Evil wins due to too many failed proposals
      %{state |
        game_winner: :evil,
        phase: :game_over,
        failed_votes: new_failed_votes
      }
    else
      %{state |
        current_leader_index: next_leader,
        failed_votes: new_failed_votes,
        proposed_team: []
      }
    end
  end

  @doc """
  Handles timeout for voting phase.
  """
  @spec handle_voting_timeout(GameState.t()) :: GameState.t()
  def handle_voting_timeout(state) do
    # Auto-approve votes for players who didn't vote
    missing_players = state.player_order -- Map.keys(state.votes)
    auto_votes = Enum.reduce(missing_players, state.votes, fn player_id, acc ->
      Map.put(acc, player_id, :approve)
    end)

    # Process the vote with auto-approvals
    approve_count = auto_votes |> Enum.count(fn {_, v} -> v == :approve end)
    team_approved = approve_count > length(state.player_order) / 2

    if team_approved do
      %{state |
        phase: :quest,
        votes: auto_votes,
        quest_cards: [],
        failed_votes: 0
      }
    else
      # Team rejected, move to next leader
      new_failed_votes = state.failed_votes + 1

      if new_failed_votes >= 5 do
        %{state |
          game_winner: :evil,
          phase: :game_over,
          votes: auto_votes,
          failed_votes: new_failed_votes
        }
      else
        next_leader = rem(state.current_leader_index + 1, length(state.player_order))
        %{state |
          current_leader_index: next_leader,
          phase: :team_building,
          votes: auto_votes,
          failed_votes: new_failed_votes,
          proposed_team: []
        }
      end
    end
  end

  @doc """
  Handles timeout for quest phase.
  """
  @spec handle_quest_timeout(GameState.t()) :: GameState.t()
  def handle_quest_timeout(state) do
    # Auto-play cards for players who didn't play
    current_cards = state.quest_cards || []
    missing_players = state.proposed_team -- (current_cards |> Enum.with_index() |> Enum.map(fn {_, i} -> Enum.at(state.proposed_team, i) end))

    # Auto-play based on role: good players play success, evil players play success (to not reveal themselves immediately)
    auto_cards = Enum.map(missing_players, fn player_id ->
      role = Map.get(state.roles, player_id)
      # Even evil players might play success sometimes to blend in, but for timeout we'll make them play based on role
      if role in [:evil, :assassin] and :rand.uniform(2) == 1 do
        :fail
      else
        :success
      end
    end)

    all_quest_cards = current_cards ++ auto_cards

    # Resolve quest
    quest_result = resolve_quest(all_quest_cards, length(state.player_order), state.current_quest)
    new_quest_results = state.quest_results ++ [quest_result]

    # Check win conditions
    success_count = Enum.count(new_quest_results, & &1 == :success)
    fail_count = Enum.count(new_quest_results, & &1 == :fail)

    cond do
      success_count >= 3 ->
        # Good might win, but evil gets to assassinate Merlin
        %{state |
          phase: :assassination,
          quest_results: new_quest_results,
          quest_cards: all_quest_cards
        }

      fail_count >= 3 ->
        # Evil wins
        %{state |
          game_winner: :evil,
          phase: :game_over,
          quest_results: new_quest_results,
          quest_cards: all_quest_cards
        }

      true ->
        # Continue to next quest
        next_leader = rem(state.current_leader_index + 1, length(state.player_order))
        %{state |
          current_quest: state.current_quest + 1,
          phase: :team_building,
          current_leader_index: next_leader,
          quest_results: new_quest_results,
          proposed_team: [],
          votes: %{},
          quest_cards: all_quest_cards
        }
    end
  end

  @doc """
  Handles timeout for assassination phase.
  """
  @spec handle_assassination_timeout(GameState.t()) :: GameState.t()
  def handle_assassination_timeout(state) do
    # Assassin didn't choose in time, pick random good player (not including known evil)
    evil_players = state.roles
    |> Enum.filter(fn {_, role} -> role in [:evil, :assassin] end)
    |> Enum.map(fn {player_id, _} -> player_id end)

    good_players = state.player_order -- evil_players
    random_target = Enum.random(good_players)

    merlin_id = get_merlin_id(state.roles)

    if random_target == merlin_id do
      # Evil wins by randomly hitting Merlin
      %{state | game_winner: :evil, phase: :game_over}
    else
      # Good wins
      %{state | game_winner: :good, phase: :game_over}
    end
  end

  @doc """
  Handles timeout for Lady of the Lake phase.
  """
  @spec handle_lady_of_the_lake_timeout(GameState.t()) :: GameState.t()
  def handle_lady_of_the_lake_timeout(state) do
    # Auto-use Lady of the Lake on a random valid target
    holder_id = state.lady_of_the_lake.holder
    valid_targets = state.player_order
    |> Enum.filter(fn p -> p != holder_id and p not in state.lady_of_the_lake.used_targets end)

    if length(valid_targets) > 0 do
      target_id = Enum.random(valid_targets)
      target_role = Map.get(state.roles, target_id)
      target_team = if target_role in [:evil, :assassin], do: :evil, else: :good

      new_used_targets = [target_id | state.lady_of_the_lake.used_targets]

      %{state |
        lady_of_the_lake: %{
          holder: target_id,
          used_targets: new_used_targets,
          pending_reveal: %{target: target_id, team: target_team, revealer: holder_id}
        },
        phase: :lady_reveal
      }
    else
      # No valid targets, skip to next quest
      continue_to_next_quest(state)
    end
  end

  # Player View Generation

  @doc """
  Generates a player-specific view of the game state.
  """
  @spec get_player_view(GameState.t(), String.t()) :: map()
  def get_player_view(state, player_id) do
    player_role = Map.get(state.roles, player_id)

    # Determine what this player can see
    visible_roles = case player_role do
      :merlin ->
        # Merlin sees all evil players
        state.roles |> Enum.filter(fn {_, role} -> role in [:evil, :assassin] end)
      :evil ->
        # Evil players see each other
        state.roles |> Enum.filter(fn {_, role} -> role in [:evil, :assassin] end)
      :assassin ->
        # Assassin sees other evil players
        state.roles |> Enum.filter(fn {_, role} -> role in [:evil, :assassin] end)
      _ ->
        # Good players see nothing
        []
    end

    %{
      player_id: player_id,
      role: player_role,
      visible_roles: visible_roles,
      phase: state.phase,
      players: state.players,
      player_order: state.player_order,
      current_quest: state.current_quest,
      quest_results: state.quest_results,
      current_leader: Enum.at(state.player_order, state.current_leader_index),
      proposed_team: state.proposed_team,
      votes: (if state.phase in [:quest, :team_building], do: %{}, else: state.votes),
      failed_votes: state.failed_votes,
      is_on_team: player_id in state.proposed_team,
      can_vote: state.phase == :voting,
      can_propose: state.phase == :team_building and player_id == Enum.at(state.player_order, state.current_leader_index),
      can_play_quest: state.phase == :quest and player_id in state.proposed_team,
      can_assassinate: state.phase == :assassination and Map.get(state.roles, player_id) == :assassin,
      game_winner: state.game_winner,
      lady_of_the_lake: %{
        holder: state.lady_of_the_lake.holder,
        can_use: state.phase == :lady_of_the_lake and state.lady_of_the_lake.holder == player_id,
        used_targets: state.lady_of_the_lake.used_targets,
        pending_reveal: state.lady_of_the_lake.pending_reveal,
        can_see_reveal: state.phase == :lady_reveal and
                       (state.lady_of_the_lake.pending_reveal.revealer == player_id or
                        state.lady_of_the_lake.pending_reveal.target == player_id)
      }
    }
  end

  # Helper Functions

  @doc """
  Gets the role distribution for a given player count.
  """
  @spec get_role_distribution(integer()) :: {integer(), integer()}
  def get_role_distribution(player_count) do
    case player_count do
      5 -> {3, 2}
      6 -> {4, 2}
      7 -> {4, 3}
      8 -> {5, 3}
      9 -> {6, 3}
      10 -> {6, 4}
    end
  end

  @doc """
  Assigns roles to players.
  """
  @spec assign_roles([String.t()], integer(), integer()) :: %{String.t() => atom()}
  def assign_roles(player_ids, _good_count, evil_count) do
    shuffled_players = Enum.shuffle(player_ids)

    # Assign Merlin and Assassin
    [merlin_id | rest] = shuffled_players
    {evil_players, good_players} = Enum.split(rest, evil_count - 1)
    [assassin_id | other_evil] = evil_players

    roles = %{}
    |> Map.put(merlin_id, :merlin)
    |> Map.put(assassin_id, :assassin)

    # Assign regular roles
    roles = Enum.reduce(other_evil, roles, fn id, acc -> Map.put(acc, id, :evil) end)
    roles = Enum.reduce(good_players, roles, fn id, acc -> Map.put(acc, id, :good) end)

    roles
  end

  @doc """
  Gets the required team size for a quest.
  """
  @spec get_quest_size(integer(), integer()) :: integer()
  def get_quest_size(player_count, quest_number) do
    quest_sizes = case player_count do
      5 -> [2, 3, 2, 3, 3]
      6 -> [2, 3, 4, 3, 4]
      7 -> [2, 3, 3, 4, 4]
      8 -> [3, 4, 4, 5, 5]
      9 -> [3, 4, 4, 5, 5]
      10 -> [3, 4, 4, 5, 5]
    end

    Enum.at(quest_sizes, quest_number - 1)
  end

  @doc """
  Resolves a quest based on the cards played.
  """
  @spec resolve_quest([quest_card()], integer(), integer()) :: quest_result()
  def resolve_quest(quest_cards, player_count, quest_number) do
    fail_count = Enum.count(quest_cards, & &1 == :fail)

    # 4th quest in 7+ player games needs 2 fails
    fails_needed = if player_count >= 7 and quest_number == 4, do: 2, else: 1

    if fail_count >= fails_needed, do: :fail, else: :success
  end

  @doc """
  Gets Merlin's player ID from the roles map.
  """
  @spec get_merlin_id(%{String.t() => atom()}) :: String.t()
  def get_merlin_id(roles) do
    {merlin_id, _} = Enum.find(roles, fn {_, role} -> role == :merlin end)
    merlin_id
  end

  # Game State Queries

  @doc """
  Checks if the game is over.
  """
  @spec game_over?(GameState.t()) :: boolean()
  def game_over?(state), do: state.phase == :game_over

  @doc """
  Gets the current game winner.
  """
  @spec get_game_winner(GameState.t()) :: game_winner() | nil
  def get_game_winner(state), do: state.game_winner

  @doc """
  Gets the current phase.
  """
  @spec get_phase(GameState.t()) :: atom()
  def get_phase(state), do: state.phase

  @doc """
  Gets the current quest number.
  """
  @spec get_current_quest(GameState.t()) :: integer()
  def get_current_quest(state), do: state.current_quest

  @doc """
  Gets the current leader.
  """
  @spec get_current_leader(GameState.t()) :: String.t()
  def get_current_leader(state) do
    Enum.at(state.player_order, state.current_leader_index)
  end

  @doc """
  Gets the number of failed votes.
  """
  @spec get_failed_votes(GameState.t()) :: integer()
  def get_failed_votes(state), do: state.failed_votes

  @doc """
  Gets the quest results.
  """
  @spec get_quest_results(GameState.t()) :: [quest_result()]
  def get_quest_results(state), do: state.quest_results
end
