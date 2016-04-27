defmodule Redix.Connection do
  @moduledoc false

  use Connection

  alias Redix.Protocol
  alias Redix.Utils
  alias Redix.Connection.Receiver
  alias Redix.Connection.SharedState

  require Logger

  @type state :: %__MODULE__{}

  defstruct [
    # The TCP socket that holds the connection to Redis
    socket: nil,
    # Options passed when the connection is started
    opts: nil,
    # The receiver process
    receiver: nil,
    # The shared state store process
    shared_state: nil,
    # The current backoff (used to compute the next backoff when reconnecting
    # with exponential backoff)
    backoff_current: nil,
  ]

  @backoff_exponent 1.5

  ## Public API

  def start_link(redis_opts, other_opts) do
    {redix_opts, connection_opts} = Utils.sanitize_starting_opts(redis_opts, other_opts)
    Connection.start_link(__MODULE__, redix_opts, connection_opts)
  end

  def stop(conn) do
    Connection.cast(conn, :stop)
  end

  def pipeline(conn, commands, timeout) do
    request_id = make_ref()

    # All this try-catch dance is required in order to cleanly return {:error,
    # :timeout} on timeouts instead of exiting (which is what `GenServer.call/3`
    # does). The whole process is described in Redix.Connection.TimeoutStore.
    try do
      {^request_id, resp} = Connection.call(conn, {:commands, commands, request_id}, timeout)
      resp
    catch
      :exit, {:timeout, {:gen_server, :call, [^conn | _]}} ->
        Connection.call(conn, {:timed_out, request_id})

        # We try to flush the response because it may have arrived before the
        # connection processed the :timed_out message. In case it arrived, we
        # notify the conncetion that it arrived (canceling the :timed_out
        # message).
        receive do
          {ref, {^request_id, _resp}} when is_reference(ref) ->
            Connection.call(conn, {:cancel_timed_out, request_id})
        after
          0 -> :ok
        end

        {:error, :timeout}
    end
  end

  ## Callbacks

  @doc false
  def init(opts) do
    state = %__MODULE__{opts: opts}

    if opts[:sync_connect] do
      sync_connect(state)
    else
      {:connect, :init, state}
    end
  end

  @doc false
  def connect(info, state)

  def connect(info, state) do
    case Utils.connect(state) do
      {:ok, state} ->
        {:ok, shared_state} = SharedState.start_link()
        receiver = start_receiver_and_hand_socket(state.socket, shared_state)

        # If this is a reconnection attempt, log that we successfully
        # reconnected.
        if info == :backoff do
          Logger.info ["Reconnected to Redis (", Utils.format_host(state), ?)]
        end

        state = %{state | shared_state: shared_state, receiver: receiver}
        {:ok, state}
      {:error, reason} ->
        Logger.error [
          "Failed to connect to Redis (", Utils.format_host(state), "): ",
          Utils.format_error(reason),
        ]

        next_backoff = calc_next_backoff(state.backoff_current || state.opts[:backoff_initial], state.opts[:backoff_max])
        {:backoff, next_backoff, %{state | backoff_current: next_backoff}}
      other ->
        other
    end
  end

  @doc false
  def disconnect(reason, state)

  def disconnect(:stop, state) do
    {:stop, :normal, state}
  end

  def disconnect({:error, reason} = _error, state) do
    Logger.error [
      "Disconnected from Redis (", Utils.format_host(state), "): ", Utils.format_error(reason),
    ]

    :ok = :gen_tcp.close(state.socket)

    state =
      if state.receiver do
        :ok = Receiver.stop(state.receiver)
        :ok = flush_messages_from_receiver(state)
        %{state | receiver: nil}
      else
        state
      end

    :ok = SharedState.disconnect_clients_and_stop(state.shared_state)

    state = %{state | socket: nil, backoff_current: state.opts[:backoff_initial]}
    {:backoff, state.opts[:backoff_initial], state}
  end

  @doc false
  def handle_call(operation, from, state)

  # When the socket is `nil`, that's a good way to tell we're disconnected.
  def handle_call({:commands, _commands, request_id}, _from, %{socket: nil} = state) do
    {:reply, {request_id, {:error, :closed}}, state}
  end

  def handle_call(_operation, _from, %{socket: nil} = state) do
    {:reply, {:error, :closed}, state}
  end

  def handle_call({:commands, commands, request_id}, from, state) do
    :ok = SharedState.enqueue(state.shared_state, {:commands, request_id, from, length(commands)})

    data = Enum.map(commands, &Protocol.pack/1)
    case :gen_tcp.send(state.socket, data) do
      :ok ->
        {:noreply, state}
      {:error, _reason} = error ->
        {:disconnect, error, state}
    end
  end

  def handle_call({:timed_out, request_id}, _from, state) do
    :ok = SharedState.add_timed_out_request(state.shared_state, request_id)
    {:reply, :ok, state}
  end

  def handle_call({:cancel_timed_out, request_id}, _from, state) do
    :ok = SharedState.cancel_timed_out_request(state.shared_state, request_id)
    {:reply, :ok, state}
  end

  @doc false
  def handle_cast(operation, state)

  def handle_cast(:stop, state) do
    {:disconnect, :stop, state}
  end

  @doc false
  def handle_info(msg, state)

  def handle_info({:receiver, pid, msg}, %{receiver: pid} = state) do
    handle_msg_from_receiver(msg, state)
  end

  ## Helper functions

  defp sync_connect(state) do
    case Utils.connect(state) do
      {:ok, state} ->
        {:ok, shared_state} = SharedState.start_link()
        receiver = start_receiver_and_hand_socket(state.socket, shared_state)
        state = %{state | shared_state: shared_state, receiver: receiver}
        {:ok, state}
      {:error, reason} ->
        {:stop, reason}
      {:stop, reason, _state} ->
        {:stop, reason}
    end
  end

  defp start_receiver_and_hand_socket(socket, shared_state) do
    {:ok, receiver} = Receiver.start_link(sender: self(), socket: socket, shared_state: shared_state)
    :ok = :gen_tcp.controlling_process(socket, receiver)
    receiver
  end

  defp handle_msg_from_receiver({:tcp_closed, socket}, %{socket: socket} = state) do
    state = %{state | receiver: nil}
    {:disconnect, {:error, :disconnected}, state}
  end

  defp handle_msg_from_receiver({:tcp_error, socket, reason}, %{socket: socket} = state) do
    state = %{state | receiver: nil}
    {:disconnect, {:error, reason}, state}
  end

  defp flush_messages_from_receiver(%{receiver: receiver} = state) do
    receive do
      {:receiver, ^receiver, _msg} -> flush_messages_from_receiver(state)
    after
      0 -> :ok
    end
  end

  defp calc_next_backoff(backoff_current, backoff_max) do
    next_exponential_backoff = round(backoff_current * @backoff_exponent)

    if backoff_max == :infinity do
      next_exponential_backoff
    else
      min(next_exponential_backoff, backoff_max)
    end
  end
end
