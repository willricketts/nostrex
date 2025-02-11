defmodule NostrexWeb.NostrSocket do
  # NOT USING Phoenix.Socket because it requires a proprietary wire protocol that is incompatible with Nostr
  require Logger

  alias Nostrex.Events
  alias Nostrex.Events.Filter
  alias Nostrex.FastFilter
  alias NostrexWeb.MessageParser
  alias Phoenix.PubSub

  @moduledoc """
  Simple Websocket handler that echos back any data it receives
  """

  @behaviour :cowboy_websocket

  # entry point of the websocket socket.
  # WARNING: this is where you would need to do any authentication
  #          and authorization. Since this handler is invoked BEFORE
  #          our Phoenix router, it will NOT follow your pipelines defined there.
  #
  # WARNING: this function is NOT called in the same process context as the rest of the functions
  #          defined in this module. This is notably dissimilar to other gen_* behaviours.
  # Phoenix.PubSub.broadcast(:nostrex_pubsub, "test", %{a: 1})
  @impl :cowboy_websocket
  def init(req, opts) do
    Logger.info("Starting cowboy websocket server")
    # TODO: look at limiting max frame size here
    # NOTE: idle timeout default is 60s to save resources
    {:cowboy_websocket, req, opts}
  end

  # as long as `init/2` returned `{:cowboy_websocket, req, opts}`
  # this function will be called. You can begin sending packets at this point.
  # We'll look at how to do that in the `websocket_handle` function however.
  # This function is where you might want to  implement `Phoenix.Presence`, schedule an `after_join` message etc.
  @impl :cowboy_websocket
  def websocket_init(state) do
    Logger.info("Websocket init state: #{state}")

    initial_state = %{
      event_count: 0,
      req_count: 0,
      subscriptions: %{}
    }

    {[], initial_state}
  end

  # `websocket_handle` is where data from a client will be received.
  # a `frame` will be delivered in one of a few shapes depending on what the client sent:
  #
  #     :ping
  #     :pong
  #     {:text, data}
  #     {:binary, data}
  #
  # Similarly, the return value of this function is similar:
  #
  #     {[reply_frame1, reply_frame2, ....], state}
  #
  # where `reply_frame` is the same format as what is delivered.
  @impl :cowboy_websocket
  def websocket_handle(frame, state)

  # Implement basic ping pong handler for easy health checking
  def websocket_handle({:text, "ping"}, state) do
    Logger.info("Ping endpoint hit")
    {[text: "pong"], state}
  end

  # Handles all Nostr [EVENT] messages. This endpoint is very DB write heavy
  # and is called by clients to publishing new Nostr events
  def websocket_handle({:text, req = "[\"EVENT\"," <> _}, state) do
    Logger.info("Inbound EVENT message: #{req}")
    event_params = MessageParser.parse_and_sanity_check_event_message(req)

    Logger.info("Creating event with params #{inspect(event_params)}")

    resp =
      case Events.create_event(event_params) do
        {:ok, event} ->
          FastFilter.process_event(event)
          gen_notice("successfully created event #{event.id}")

        {:error, errors} ->
          Logger.error("failed to save event #{inspect(errors)}")
          gen_notice("error: unable to save event")
      end

    new_state = increment_state_counter(state, :event_count)

    {[text: resp], new_state}
  end

  @doc """
  Handles all Nostr [REQ] messages. This endpoint is very DB read heavy
  and also grows the in-memory PubSub state. It's used by clients
  to query and subscribe to events based on a filter
  """
  def websocket_handle({:text, req = "[\"REQ\"," <> _}, state) do
    Logger.info("Inbound REQ message: #{req}")

    {:ok, list} = Jason.decode(req, keys: :atoms)
    [_, subscription_id | filters] = list

    # TODO, ensure subscription_id doesn't have colon since we use as separator in filter_id
    new_state =
      state
      |> handle_req_event(subscription_id, filters)
      |> increment_state_counter(:req_count)

    resp = gen_notice("successfully created subscription #{subscription_id}")

    {[text: resp], new_state}
  end

  # Handles all Nostr [CLOSE] messages. This endpoint is very DB read heavy
  # and also grows the in-memory PubSub state. This message includes a subscription
  # id, but we need to be sure we're only closing the subscription ids that belong to this
  # channel, otherwise we open ourselves up to somebody spamming in an attempt to close
  # subscriptions for other clients
  def websocket_handle({:text, req = "[\"CLOSE\"," <> _}, state) do
    Logger.info("Inbound Close message #{req}")

    {:ok, list} = Jason.decode(req)

    # TODO, validate subscription ID
    subscription_id = Enum.at(list, 1)
    remove_subscription(state, subscription_id)

    {[close: "success"], state}
  end

  # # a message was delivered from a client. Here we handle it by just echoing it back
  # # to the client.
  # def websocket_handle({:text, message}, state) do
  # 	{[{:text, message}], state}
  # end

  # # This function is where we will process all *other* messages that get delivered to the
  # # process mailbox. This function isn't used in this handler.
  @impl :cowboy_websocket
  def websocket_info(info, state)

  def websocket_info({:events, events, subscription_id}, state) when is_list(events) do
    Logger.info("Sending events #{inspect(events)} to subscription #{subscription_id}")
    event_json = MessageParser.generate_event_list_response(events, subscription_id)
    {[text: event_json], state}
  end

  def websocket_info(info, state) do
    msgs = Process.info(self(), :messages)

    Logger.error("""
    default websocket event handler (shouldn't be called)
    #{inspect(info)}
    #{inspect(state)}
    #{inspect(msgs)}
    """)

    {[text: "handling shouldn't be called"], state}
  end

  # placeholder catch all
  def handle_info(_) do
    Logger.info("Catch-all handle_info called")
  end

  @impl true
  def terminate(_reason, _partial_req, state) do
    ## Ensure any state gets cleaned up before terminating
    state.subscriptions
    |> Enum.each(fn {sub_id, _set} ->
      remove_subscription(state, sub_id)
    end)

    Logger.info("Websocket terminate called with state: #{inspect(state)}")
    :ok
  end

  # increments a counter on the state object
  defp increment_state_counter(state, key) do
    put_in(state, [key], state[key] + 1)
  end

  defp handle_req_event(state, _subscription_id, filters) when filters == [] do
    state
  end

  defp handle_req_event(state, subscription_id, unsanitized_filter_params) do
    # TODO move to safer place to only happen for future subscriptions, not all
    # register the subscriber
    PubSub.subscribe(:nostrex_pubsub, subscription_id)

    # TODO check subscription doesn't already exist
    state = put_in(state, [:subscriptions, subscription_id], MapSet.new())

    filters =
      unsanitized_filter_params
      |> Enum.map(fn params ->
        params
        |> Map.put(:subscription_id, subscription_id)
        |> Events.create_filter()
      end)

    # Iterate through filters, but use reduce to update state object throughout
    Enum.reduce(filters, state, fn filter, state ->
      # first get historical data for any filter
      query_and_return_historical_events(filter)

      # then subscribe to future events if relevant
      # it will return state object
      setup_future_subscription(filter, state, subscription_id)
    end)
  end

  defp query_and_return_historical_events(filter = %Filter{}) do
    Logger.info("Querying historical events for subscription: #{filter.subscription_id}")
    # query db for events and broadcast back to this subscribing socket
    Events.get_events_matching_filter_and_broadcast(filter)
  end

  defp setup_future_subscription(filter, state, subscription_id) do
    if filter.until == nil or !timestamp_before_now?(filter.until) do
      filter
      |> FastFilter.insert_filter()

      update_in(state, [:subscriptions, subscription_id], &MapSet.put(&1, filter))
    else
      state
    end
  end

  defp remove_subscription(state, subscription_id) do
    Logger.info("Cleanup subscription #{subscription_id} from ETS")

    filters = get_in(state, [:subscriptions, subscription_id])

    if filters != nil do
      Enum.each(filters, fn filter ->
        FastFilter.delete_filter(filter)
      end)
    end

    update_in(state.subscriptions, &Map.delete(&1, subscription_id))
  end

  # TODO: consider adding some larger buffer here
  defp timestamp_before_now?(unix_timestamp) do
    DateTime.compare(DateTime.from_unix!(unix_timestamp), DateTime.utc_now()) == :lt
  end

  defp gen_notice(message) do
    ~s(["NOTICE", "#{message}"])
  end
end
