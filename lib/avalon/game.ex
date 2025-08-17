defmodule Avalon.Game do
  use GenServer
  require Logger

  defmodule GameState do
    defstruct [
      :id,
      :players,
      :player_order,
      :roles,
      :phase,
      :current_quest,
      :quest_results,
      :current_leader_index,
      :proposed_team,
      :votes,
      :failed_votes,
      :quest_cards,
      :game_winner,
      :timer_ref,
      :phase_deadline,
      :phase_start_time,
      :lady_of_the_lake
    ]
  end

  # Client API
  def start_link(game_id) do
    GenServer.start_link(__MODULE__, %{game_id: game_id}, name: via_tuple(game_id))
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

  def reconnect_player(game_id, player_id) do
    GenServer.call(via_tuple(game_id), {:reconnect_player, player_id})
  end

  def clear_reconnected_flags(game_id) do
    GenServer.call(via_tuple(game_id), :clear_reconnected_flags)
  end

  defp via_tuple(game_id) do
    {:via, Registry, {Avalon.Registry, game_id}}
  end

  # Server Callbacks
  def init(%{game_id: game_id}) do
    state = %GameState{
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
    case Avalon.GameLogic.join_game(state, player_name) do
      {:ok, player_id, new_state} ->
        broadcast_game_update(new_state)
        {:reply, {:ok, player_id}, new_state}
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:start_game, _from, state) do
    case Avalon.GameLogic.start_game(state) do
      {:ok, new_state} ->
        new_state = start_phase_timer(new_state, :team_building, 10 * 60 * 1000) # 10 minutes for team building
        broadcast_game_update(new_state)
        {:reply, :ok, new_state}
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:propose_team, player_id, team_members}, _from, state) do
    case Avalon.GameLogic.propose_team(state, player_id, team_members) do
      {:ok, new_state} ->
        new_state = start_phase_timer(new_state, :voting, 60 * 1000) # 1 minute for voting
        broadcast_game_update(new_state)
        {:reply, :ok, new_state}
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:vote_team, player_id, vote}, _from, state) do
    case Avalon.GameLogic.vote_on_team(state, player_id, vote) do
      {:ok, new_state} ->
        # Check if we need to start a timer for the new phase
        new_state = case new_state.phase do
          :quest -> start_phase_timer(new_state, :quest, 30 * 1000) # 30 seconds for quest cards
          :team_building -> start_phase_timer(new_state, :team_building, 10 * 60 * 1000) # 10 minutes for team building
          _ -> new_state
        end
        broadcast_game_update(new_state)
        {:reply, :ok, new_state}
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:quest_card, player_id, card}, _from, state) do
    case Avalon.GameLogic.play_quest_card(state, player_id, card) do
      {:ok, new_state} ->
        # Check if we need to start a timer for the new phase
        new_state = case new_state.phase do
          :assassination -> start_phase_timer(new_state, :assassination, 2 * 60 * 1000) # 2 minutes for assassination
          :team_building -> start_phase_timer(new_state, :team_building, 10 * 60 * 1000) # 10 minutes for next team building
          _ -> new_state
        end
        broadcast_game_update(new_state)
        {:reply, :ok, new_state}
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:assassinate, target_player_id}, _from, state) do
    case Avalon.GameLogic.assassinate(state, target_player_id) do
      {:ok, new_state} ->
        broadcast_game_update(new_state)
        {:reply, :ok, new_state}
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:use_lady_of_the_lake, player_id, target_id}, _from, state) do
    case Avalon.GameLogic.use_lady_of_the_lake(state, player_id, target_id) do
      {:ok, new_state} ->
        new_state = start_phase_timer(new_state, :lady_reveal, 10 * 1000)
        broadcast_game_update(new_state)
        {:reply, :ok, new_state}
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:get_state, player_id}, _from, state) do
    if Map.has_key?(state.players, player_id) do
      player_view = Avalon.GameLogic.get_player_view(state, player_id)
      |> Map.merge(%{
        time_remaining: get_time_remaining(state),
        phase_start_time: state.phase_start_time
      })
      {:reply, {:ok, player_view}, state}
    else
      {:reply, {:error, "Player not found"}, state}
    end
  end

  def handle_call({:reconnect_player, player_id}, _from, state) do
    case Avalon.GameLogic.mark_player_reconnected(state, player_id) do
      {:ok, new_state} ->
        broadcast_game_update(new_state)
        {:reply, :ok, new_state}
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:clear_reconnected_flags, _from, state) do
    case Avalon.GameLogic.clear_reconnected_flags(state) do
      {:ok, new_state} ->
        broadcast_game_update(new_state)
        {:reply, :ok, new_state}
    end
  end

  def handle_info(:phase_timeout, state) do
    handle_timeout(state)
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    {:noreply, state}
  end

  # Timeout handling for each phase
  defp handle_timeout(%{phase: :team_building} = state) do
    new_state = Avalon.GameLogic.handle_team_building_timeout(state)

    if new_state.phase == :game_over do
      new_state = cancel_timer(new_state)
      broadcast_game_update(new_state)
      {:noreply, new_state}
    else
      new_state = start_phase_timer(new_state, :team_building, 10 * 60 * 1000)
      broadcast_game_update(new_state)
      {:noreply, new_state}
    end
  end

  defp handle_timeout(%{phase: :voting} = state) do
    new_state = Avalon.GameLogic.handle_voting_timeout(state)

    case new_state.phase do
      :quest ->
        new_state = start_phase_timer(new_state, :quest, 30 * 1000)
        broadcast_game_update(new_state)
        {:noreply, new_state}
      :game_over ->
        new_state = cancel_timer(new_state)
        broadcast_game_update(new_state)
        {:noreply, new_state}
      :team_building ->
        new_state = start_phase_timer(new_state, :team_building, 10 * 60 * 1000)
        broadcast_game_update(new_state)
        {:noreply, new_state}
    end
  end

  defp handle_timeout(%{phase: :quest} = state) do
    new_state = Avalon.GameLogic.handle_quest_timeout(state)

    case new_state.phase do
      :assassination ->
        new_state = start_phase_timer(new_state, :assassination, 2 * 60 * 1000)
        broadcast_game_update(new_state)
        {:noreply, new_state}
      :game_over ->
        new_state = cancel_timer(new_state)
        broadcast_game_update(new_state)
        {:noreply, new_state}
      :team_building ->
        new_state = start_phase_timer(new_state, :team_building, 10 * 60 * 1000)
        broadcast_game_update(new_state)
        {:noreply, new_state}
    end
  end

  defp handle_timeout(%{phase: :lady_of_the_lake} = state) do
    new_state = Avalon.GameLogic.handle_lady_of_the_lake_timeout(state)

    case new_state.phase do
      :lady_reveal ->
        new_state = start_phase_timer(new_state, :lady_reveal, 10 * 1000)
        broadcast_game_update(new_state)
        {:noreply, new_state}
      :team_building ->
        new_state = start_phase_timer(new_state, :team_building, 10 * 60 * 1000)
        broadcast_game_update(new_state)
        {:noreply, new_state}
    end
  end

  defp handle_timeout(%{phase: :lady_reveal} = state) do
    # Reveal time is over, continue to next quest
    continue_to_next_quest(state)
  end

  defp handle_timeout(%{phase: :assassination} = state) do
    new_state = Avalon.GameLogic.handle_assassination_timeout(state)
    new_state = cancel_timer(new_state)
    broadcast_game_update(new_state)
    {:noreply, new_state}
  end

  defp handle_timeout(state) do
    # No timeout handling needed for other phases
    {:noreply, state}
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
    new_state = Avalon.GameLogic.continue_to_next_quest(state)
    new_state = start_phase_timer(new_state, :team_building, 10 * 60 * 1000)
    broadcast_game_update(new_state)
    new_state
  end

  defp broadcast_game_update(state) do
    # Broadcast to all players in the game
    Enum.each(state.player_order, fn player_id ->
      player_view = Avalon.GameLogic.get_player_view(state, player_id)
      |> Map.merge(%{
        time_remaining: get_time_remaining(state),
        phase_start_time: state.phase_start_time
      })
      Phoenix.PubSub.broadcast(Avalon.PubSub, "game:#{state.id}", {:game_update, player_view})
    end)
  end
end
