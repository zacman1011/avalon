defmodule Avalon.Game do
  use GenServer
  require Logger

  # Client API
  def start_link(game_id) do
    GenServer.start_link(__MODULE__, %{}, name: via_tuple(game_id))
  end

  def join_game(game_id, player_name) do
    GenServer.call(via_tuple(game_id), {:join, player_name})
  end

  def start_game(game_id) do
    GenServer.call(via_tuple(game_id), :start_game)
  end

  def propose_team(game_id, player_id, team_members) do
    GenServer.call(via_tuple(game_id), {:propose_team, player_id, team_members})
  end

  def vote_on_team(game_id, player_id, vote) do
    GenServer.call(via_tuple(game_id), {:vote_team, player_id, vote})
  end

  def play_quest_card(game_id, player_id, card) do
    GenServer.call(via_tuple(game_id), {:quest_card, player_id, card})
  end

  def assassinate(game_id, target_player_id) do
    GenServer.call(via_tuple(game_id), {:assassinate, target_player_id})
  end

  def use_lady_of_the_lake(game_id, player_id, target_id) do
    GenServer.call(via_tuple(game_id), {:use_lady_of_the_lake, player_id, target_id})
  end

  def get_game_state(game_id, player_id) do
    GenServer.call(via_tuple(game_id), {:get_state, player_id})
  end

  defp via_tuple(game_id) do
    {:via, Registry, {Avalon.Registry, game_id}}
  end

  # Server Callbacks
  def init(game_id) do
    state = %{
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
      timer_ref: nil,
      phase_deadline: nil,
      phase_start_time: nil,
      lady_of_the_lake: %{
        holder: nil,
        used_targets: [],
        pending_reveal: nil
      }
    }
    {:ok, state}
  end

  def handle_call({:join, player_name}, _from, state) do
    if length(state.player_order) >= 10 do
      {:reply, {:error, "Game is full"}, state}
    else
      player_id = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
      player = %{id: player_id, name: player_name}

      new_state = %{state |
        players: Map.put(state.players, player_id, player),
        player_order: state.player_order ++ [player_id]
      }

      broadcast_game_update(new_state)
      {:reply, {:ok, player_id}, new_state}
    end
  end

  def handle_call(:start_game, _from, state) do
    player_count = length(state.player_order)

    if player_count < 5 do
      {:reply, {:error, "Need at least 5 players"}, state}
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
      |> start_phase_timer(:team_building, 10 * 60 * 1000) # 10 minutes for team building

      broadcast_game_update(new_state)
      {:reply, :ok, new_state}
    end
  end

  def handle_call({:propose_team, player_id, team_members}, _from, state) do
    current_leader = Enum.at(state.player_order, state.current_leader_index)

    if player_id == current_leader and state.phase == :team_building do
      quest_size = get_quest_size(length(state.player_order), state.current_quest)

      if length(team_members) == quest_size do
        new_state = %{state |
          proposed_team: team_members,
          phase: :voting,
          votes: %{}
        }
        |> start_phase_timer(:voting, 60 * 1000) # 1 minute for voting

        broadcast_game_update(new_state)
        {:reply, :ok, new_state}
      else
        {:reply, {:error, "Wrong team size"}, state}
      end
    else
      {:reply, {:error, "Not your turn or wrong phase"}, state}
    end
  end

  def handle_call({:vote_team, player_id, vote}, _from, state) do
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
          |> start_phase_timer(:quest, 30 * 1000) # 30 seconds for quest cards

          broadcast_game_update(new_state)
          {:reply, :ok, new_state}
        else
          # Team rejected
          new_failed_votes = state.failed_votes + 1

          if new_failed_votes >= 5 do
            # Evil wins
            new_state = %{state | game_winner: :evil, phase: :game_over}
            broadcast_game_update(new_state)
            {:reply, :ok, new_state}
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
            |> start_phase_timer(:team_building, 10 * 60 * 1000) # 10 minutes for next team building

            broadcast_game_update(new_state)
            {:reply, :ok, new_state}
          end
        end
      else
        new_state = %{state | votes: new_votes}
        broadcast_game_update(new_state)
        {:reply, :ok, new_state}
      end
    else
      {:reply, {:error, "Cannot vote"}, state}
    end
  end

  def handle_call({:quest_card, player_id, card}, _from, state) do
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
            |> start_phase_timer(:assassination, 2 * 60 * 1000) # 2 minutes for assassination

            broadcast_game_update(new_state)
            {:reply, :ok, new_state}

          fail_count >= 3 ->
            # Evil wins
            new_state = %{state |
              game_winner: :evil,
              phase: :game_over,
              quest_results: new_quest_results,
              quest_cards: new_quest_cards
            }
            broadcast_game_update(new_state)
            {:reply, :ok, new_state}

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
            |> start_phase_timer(:team_building, 10 * 60 * 1000) # 10 minutes for next team building

            broadcast_game_update(new_state)
            {:reply, :ok, new_state}
        end
      else
        new_state = %{state | quest_cards: new_quest_cards}
        broadcast_game_update(new_state)
        {:reply, :ok, new_state}
      end
    else
      {:reply, {:error, "Cannot play quest card"}, state}
    end
  end

  def handle_call({:assassinate, target_player_id}, _from, state) do
    if state.phase == :assassination do
      merlin_id = get_merlin_id(state.roles)

      new_state = if target_player_id == merlin_id do
        # Evil wins by assassinating Merlin
        %{state | game_winner: :evil, phase: :game_over}
      else
        # Good wins
        %{state | game_winner: :good, phase: :game_over}
      end

      broadcast_game_update(new_state)
      {:reply, :ok, new_state}
    else
      {:reply, {:error, "Cannot assassinate now"}, state}
    end
  end

  def handle_call({:use_lady_of_the_lake, player_id, target_id}, _from, state) do
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
      |> start_phase_timer(:lady_reveal, 10 * 1000)

      broadcast_game_update(new_state)
      {:reply, :ok, new_state}
    else
      {:reply, {:error, "Cannot use Lady of the Lake"}, state}
    end
  end

  def handle_call({:get_state, player_id}, _from, state) do
    player_view = get_player_view(state, player_id)
    {:reply, player_view, state}
  end

  def handle_info(:phase_timeout, state) do
    handle_timeout(state)
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    {:noreply, state}
  end

  # Timeout handling for each phase
  defp handle_timeout(%{phase: :team_building} = state) do
    # Leader didn't propose in time, move to next leader
    next_leader = rem(state.current_leader_index + 1, length(state.player_order))
    new_failed_votes = state.failed_votes + 1

    if new_failed_votes >= 5 do
      # Evil wins due to too many failed proposals
      new_state = %{state |
        game_winner: :evil,
        phase: :game_over,
        failed_votes: new_failed_votes
      }
      |> cancel_timer()

      broadcast_game_update(new_state)
      {:noreply, new_state}
    else
      new_state = %{state |
        current_leader_index: next_leader,
        failed_votes: new_failed_votes,
        proposed_team: []
      }
      |> start_phase_timer(:team_building, 10 * 60 * 1000)

      broadcast_game_update(new_state)
      {:noreply, new_state}
    end
  end

  defp handle_timeout(%{phase: :voting} = state) do
    # Auto-approve votes for players who didn't vote
    missing_players = state.player_order -- Map.keys(state.votes)
    auto_votes = Enum.reduce(missing_players, state.votes, fn player_id, acc ->
      Map.put(acc, player_id, :approve)
    end)

    # Process the vote with auto-approvals
    approve_count = auto_votes |> Enum.count(fn {_, v} -> v == :approve end)
    team_approved = approve_count > length(state.player_order) / 2

    if team_approved do
      new_state = %{state |
        phase: :quest,
        votes: auto_votes,
        quest_cards: [],
        failed_votes: 0
      }
      |> start_phase_timer(:quest, 30 * 1000)

      broadcast_game_update(new_state)
      {:noreply, new_state}
    else
      # Team rejected, move to next leader
      new_failed_votes = state.failed_votes + 1

      if new_failed_votes >= 5 do
        new_state = %{state |
          game_winner: :evil,
          phase: :game_over,
          votes: auto_votes,
          failed_votes: new_failed_votes
        }
        |> cancel_timer()

        broadcast_game_update(new_state)
        {:noreply, new_state}
      else
        next_leader = rem(state.current_leader_index + 1, length(state.player_order))
        new_state = %{state |
          current_leader_index: next_leader,
          phase: :team_building,
          votes: auto_votes,
          failed_votes: new_failed_votes,
          proposed_team: []
        }
        |> start_phase_timer(:team_building, 10 * 60 * 1000)

        broadcast_game_update(new_state)
        {:noreply, new_state}
      end
    end
  end

  defp handle_timeout(%{phase: :quest} = state) do
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
        new_state = %{state |
          phase: :assassination,
          quest_results: new_quest_results,
          quest_cards: all_quest_cards
        }
        |> start_phase_timer(:assassination, 2 * 60 * 1000)

        broadcast_game_update(new_state)
        {:noreply, new_state}

      fail_count >= 3 ->
        # Evil wins
        new_state = %{state |
          game_winner: :evil,
          phase: :game_over,
          quest_results: new_quest_results,
          quest_cards: all_quest_cards
        }
        |> cancel_timer()

        broadcast_game_update(new_state)
        {:noreply, new_state}

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
          quest_cards: all_quest_cards
        }
        |> start_phase_timer(:team_building, 10 * 60 * 1000)

        broadcast_game_update(new_state)
        {:noreply, new_state}
    end
  end

  defp handle_timeout(%{phase: :lady_of_the_lake} = state) do
    # Auto-use Lady of the Lake on a random valid target
    holder_id = state.lady_of_the_lake.holder
    valid_targets = state.player_order
    |> Enum.filter(fn p -> p != holder_id and p not in state.lady_of_the_lake.used_targets end)

    if length(valid_targets) > 0 do
      target_id = Enum.random(valid_targets)
      target_role = Map.get(state.roles, target_id)
      target_team = if target_role in [:evil, :assassin], do: :evil, else: :good

      new_used_targets = [target_id | state.lady_of_the_lake.used_targets]

      new_state = %{state |
        lady_of_the_lake: %{
          holder: target_id,
          used_targets: new_used_targets,
          pending_reveal: %{target: target_id, team: target_team, revealer: holder_id}
        },
        phase: :lady_reveal
      }
      |> start_phase_timer(:lady_reveal, 10 * 1000)

      broadcast_game_update(new_state)
      {:noreply, new_state}
    else
      # No valid targets, skip to next quest
      continue_to_next_quest(state)
    end
  end

  defp handle_timeout(%{phase: :lady_reveal} = state) do
    # Reveal time is over, continue to next quest
    continue_to_next_quest(state)
  end

  defp handle_timeout(%{phase: :assassination} = state) do
    # Assassin didn't choose in time, pick random good player (not including known evil)
    evil_players = state.roles
    |> Enum.filter(fn {_, role} -> role in [:evil, :assassin] end)
    |> Enum.map(fn {player_id, _} -> player_id end)

    good_players = state.player_order -- evil_players
    random_target = Enum.random(good_players)

    merlin_id = get_merlin_id(state.roles)

    new_state = if random_target == merlin_id do
      # Evil wins by randomly hitting Merlin
      %{state | game_winner: :evil, phase: :game_over}
    else
      # Good wins
      %{state | game_winner: :good, phase: :game_over}
    end
    |> cancel_timer()

    broadcast_game_update(new_state)
    {:noreply, new_state}
  end

  defp handle_timeout(state) do
    # No timeout handling needed for other phases
    {:noreply, state}
  end

  # Helper functions
  defp get_role_distribution(player_count) do
    case player_count do
      5 -> {3, 2}
      6 -> {4, 2}
      7 -> {4, 3}
      8 -> {5, 3}
      9 -> {6, 3}
      10 -> {6, 4}
    end
  end

  defp assign_roles(player_ids, _good_count, evil_count) do
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

  defp get_quest_size(player_count, quest_number) do
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

  defp resolve_quest(quest_cards, player_count, quest_number) do
    fail_count = Enum.count(quest_cards, & &1 == :fail)

    # 4th quest in 7+ player games needs 2 fails
    fails_needed = if player_count >= 7 and quest_number == 4, do: 2, else: 1

    if fail_count >= fails_needed, do: :fail, else: :success
  end

  defp get_merlin_id(roles) do
    {merlin_id, _} = Enum.find(roles, fn {_, role} -> role == :merlin end)
    merlin_id
  end

  defp get_player_view(state, player_id) do
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
      time_remaining: get_time_remaining(state),
      phase_start_time: state.phase_start_time,
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

  defp get_time_remaining(state) do
    case {state.phase_deadline, state.phase_start_time} do
      {deadline, start_time} when is_integer(deadline) and is_integer(start_time) ->
        remaining = deadline - System.monotonic_time(:millisecond)
        if remaining > 0, do: remaining, else: 0
      _ ->
        nil
    end
  end

  defp start_phase_timer(state, _phase, duration) do
    # Cancel existing timer
    state = cancel_timer(state)

    # Start new timer
    timer_ref = Process.send_after(self(), :phase_timeout, duration)

    %{state |
      timer_ref: timer_ref,
      phase_deadline: System.monotonic_time(:millisecond) + duration,
      phase_start_time: System.monotonic_time(:millisecond)
    }
  end

  defp cancel_timer(state) do
    if state.timer_ref do
      Process.cancel_timer(state.timer_ref)
    end

    %{state |
      timer_ref: nil,
      phase_deadline: nil,
      phase_start_time: nil
    }
  end

  defp continue_to_next_quest(state) do
    next_leader = rem(state.current_leader_index + 1, length(state.player_order))
    new_state = %{state |
      current_quest: state.current_quest + 1,
      phase: :team_building,
      current_leader_index: next_leader,
      proposed_team: [],
      votes: %{},
      lady_of_the_lake: Map.put(state.lady_of_the_lake, :pending_reveal, nil)
    }
    |> start_phase_timer(:team_building, 10 * 60 * 1000)

    broadcast_game_update(new_state)
    new_state
  end

  defp broadcast_game_update(state) do
    # Broadcast to all players in the game
    Enum.each(state.player_order, fn player_id ->
      player_view = get_player_view(state, player_id)
      Phoenix.PubSub.broadcast(Avalon.PubSub, "game:#{state.id}", {:game_update, player_view})
    end)
  end
end
