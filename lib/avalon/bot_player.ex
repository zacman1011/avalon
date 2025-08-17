defmodule Avalon.BotPlayer do
  use GenServer
  require Logger

  @doc """
  Starts a bot player that will join and play in the specified game.
  """
  def start_link(game_id, bot_name) do
    GenServer.start_link(__MODULE__, {game_id, bot_name}, name: via_tuple(game_id, bot_name))
  end

  @doc """
  Stops a bot player.
  """
  def stop_bot(game_id, bot_name) do
    GenServer.stop(via_tuple(game_id, bot_name))
  end

  defp via_tuple(game_id, bot_name) do
    {:via, Registry, {Avalon.Registry, "bot:#{game_id}:#{bot_name}"}}
  end

  # Server Callbacks
  def init({game_id, bot_name}) do
    # Subscribe to game updates
    Phoenix.PubSub.subscribe(Avalon.PubSub, "game:#{game_id}")

    # Join the game
    case Avalon.Game.join_game(game_id, bot_name) do
      {:ok, player_id} ->
        Logger.info("Bot #{bot_name} joined game #{game_id} as player #{player_id}")
        {:ok, %{game_id: game_id, bot_name: bot_name, player_id: player_id}}
      {:error, reason} ->
        Logger.error("Bot #{bot_name} failed to join game #{game_id}: #{reason}")
        {:stop, :join_failed}
    end
  end

  def handle_info({:game_update, game_state}, state) do
    # Only act if this is our bot's turn or we need to make a decision
    if should_act?(game_state, state.player_id) do
      # Add a small delay to make it feel more natural
      Process.send_after(self(), {:act, game_state}, random_delay())
    end

    {:noreply, state}
  end

  def handle_info({:act, game_state}, state) do
    perform_action(game_state, state)
    {:noreply, state}
  end

  def handle_info(_message, state) do
    {:noreply, state}
  end

  # Determine if the bot should act in the current game state
  defp should_act?(game_state, player_id) do
    case game_state.phase do
      :team_building ->
        # Act if we're the current leader
        game_state.current_leader == player_id
      :voting ->
        # Act if we haven't voted yet
        not Map.has_key?(game_state.votes, player_id)
      :quest ->
        # Act if we're on the team and haven't played a card yet
        player_id in game_state.proposed_team and
        not Enum.any?(game_state.quest_cards || [], fn _ -> true end)
      :assassination ->
        # Act if we're the assassin
        game_state.can_assassinate
      :lady_of_the_lake ->
        # Act if we have the Lady of the Lake
        game_state.lady_of_the_lake.can_use
      _ ->
        false
    end
  end

  # Perform the appropriate action based on the game state
  defp perform_action(game_state, state) do
    case game_state.phase do
      :team_building ->
        propose_random_team(game_state, state)
      :voting ->
        vote_randomly(game_state, state)
      :quest ->
        play_random_quest_card(game_state, state)
      :assassination ->
        assassinate_randomly(game_state, state)
      :lady_of_the_lake ->
        use_lady_randomly(game_state, state)
      _ ->
        :ok
    end
  end

  # Propose a random team of the correct size
  defp propose_random_team(game_state, state) do
    required_size = get_required_team_size(game_state)
    available_players = game_state.player_order

    team = available_players
    |> Enum.shuffle()
    |> Enum.take(required_size)

    Logger.info("Bot #{state.bot_name} proposing team: #{inspect(team)}")
    Avalon.Game.propose_team(state.game_id, state.player_id, team)
  end

  # Vote randomly (approve or reject)
  defp vote_randomly(_game_state, state) do
    vote = if :rand.uniform(2) == 1, do: :approve, else: :reject
    Logger.info("Bot #{state.bot_name} voting: #{vote}")
    Avalon.Game.vote_on_team(state.game_id, state.player_id, vote)
  end

  # Play a quest card based on role
  defp play_random_quest_card(game_state, state) do
    role = game_state.role

    card = case role do
      :good ->
        # Good players always play success
        :success
      :merlin ->
        # Merlin always plays success
        :success
      :evil ->
        # Evil players can play either, but tend to play fail more often
        if :rand.uniform(3) <= 2, do: :fail, else: :success
      :assassin ->
        # Assassin can play either, but tends to play fail more often
        if :rand.uniform(3) <= 2, do: :fail, else: :success
      _ ->
        # Default to success for unknown roles
        :success
    end

    Logger.info("Bot #{state.bot_name} (role: #{role}) playing card: #{card}")
    Avalon.Game.play_quest_card(state.game_id, state.player_id, card)
  end

  # Assassinate a random good player (excluding known evil players)
  defp assassinate_randomly(game_state, state) do
    # Get all players that the assassin can see (excluding known evil)
    known_evil = Map.keys(game_state.visible_roles)
    available_targets = game_state.player_order -- known_evil

    if length(available_targets) > 0 do
      target = Enum.random(available_targets)
      Logger.info("Bot #{state.bot_name} assassinating: #{target}")
      Avalon.Game.assassinate(state.game_id, target)
    else
      # Fallback: assassinate any player
      target = Enum.random(game_state.player_order)
      Logger.info("Bot #{state.bot_name} assassinating (fallback): #{target}")
      Avalon.Game.assassinate(state.game_id, target)
    end
  end

  # Use Lady of the Lake on a random valid target
  defp use_lady_randomly(game_state, state) do
    used_targets = game_state.lady_of_the_lake.used_targets
    available_targets = game_state.player_order -- used_targets -- [state.player_id]

    if length(available_targets) > 0 do
      target = Enum.random(available_targets)
      Logger.info("Bot #{state.bot_name} using Lady of the Lake on: #{target}")
      Avalon.Game.use_lady_of_the_lake(state.game_id, state.player_id, target)
    else
      Logger.warning("Bot #{state.bot_name} has no valid targets for Lady of the Lake")
    end
  end

  # Get the required team size for the current quest
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

  # Add a random delay between 1-3 seconds to make bot actions feel more natural
  defp random_delay do
    :rand.uniform(2000) + 1000
  end
end
