defmodule Kadabra.Stream do
  @moduledoc false

  defstruct id: nil,
            body: "",
            client: nil,
            connection: nil,
            socket: nil,
            ref: nil,
            flow: nil,
            headers: [],
            on_response: nil

  require Logger

  alias Kadabra.{Encodable, Frame, Hpack, Socket, Stream, Tasks}

  alias Kadabra.Frame.{
    Continuation,
    Data,
    Headers,
    PushPromise,
    RstStream,
    WindowUpdate
  }

  alias Kadabra.Stream.Response

  @type t :: %__MODULE__{
          id: pos_integer,
          client: pid,
          connection: pid,
          ref: term,
          flow: Kadabra.Stream.FlowControl.t(),
          headers: [...],
          body: binary
        }

  @closed :closed
  @hc_local :half_closed_local
  @hc_remote :half_closed_remote
  @idle :idle
  @open :open
  # @reserved_local :reserved_local
  @reserved_remote :reserved_remote

  def new(config, stream_id, initial_window_size, max_frame_size) do
    flow_opts = [
      window: initial_window_size,
      max_frame_size: max_frame_size
    ]

    %__MODULE__{
      id: stream_id,
      client: config.client,
      ref: config.ref,
      socket: config.socket,
      connection: self(),
      flow: Stream.FlowControl.new(flow_opts)
    }
  end

  def start_link(%Stream{} = stream) do
    :gen_statem.start_link(__MODULE__, stream, [])
  end

  def close(pid) do
    call_recv(pid, :close)
  end

  def call_recv(pid, frame) do
    :gen_statem.call(pid, {:recv, frame})
  end

  def cast_send(pid, frame) do
    :gen_statem.cast(pid, {:send, frame})
  end

  # recv

  def recv(from, :close, _state, _stream) do
    {:stop, :normal, [{:reply, from, :ok}]}
  end

  def recv(from, %WindowUpdate{window_size_increment: inc}, _state, stream) do
    flow =
      stream.flow
      |> Stream.FlowControl.increment_window(inc)
      |> Stream.FlowControl.process()
      |> send_data_frames(stream.socket, stream.id)

    {:keep_state, %{stream | flow: flow}, [{:reply, from, :ok}]}
  end

  def recv(from, %Data{end_stream: true, data: data}, state, stream)
      when state in [@hc_local] do
    :gen_statem.reply(from, :ok)
    stream = %Stream{stream | body: stream.body <> data}
    {:next_state, @closed, stream}
  end

  def recv(from, %Data{end_stream: true, data: data}, _state, stream) do
    :gen_statem.reply(from, :ok)
    stream = %Stream{stream | body: stream.body <> data}
    {:next_state, @hc_remote, stream}
  end

  def recv(from, %Data{end_stream: false, data: data}, _state, stream) do
    :gen_statem.reply(from, :ok)
    stream = %Stream{stream | body: stream.body <> data}
    {:keep_state, stream}
  end

  def recv(from, %Headers{end_stream: true} = frame, _state, stream) do
    :gen_statem.reply(from, :ok)
    stream = %Stream{stream | headers: stream.headers ++ frame.headers}

    {:next_state, @hc_remote, stream}
  end

  def recv(from, %Headers{end_stream: false} = frame, _state, stream) do
    :gen_statem.reply(from, :ok)
    stream = %Stream{stream | headers: stream.headers ++ frame.headers}

    {:keep_state, stream}
  end

  def recv(from, %RstStream{} = _frame, state, stream)
      when state in [@open, @hc_local, @hc_remote, @closed] do
    # IO.inspect(frame, label: "Got RST_STREAM")
    {:next_state, :closed, stream, [{:reply, from, :ok}]}
  end

  def recv(from, %PushPromise{} = frame, state, stream)
      when state in [@idle] do
    :gen_statem.reply(from, :ok)

    stream = %Stream{stream | headers: stream.headers ++ frame.headers}

    response = Response.new(stream.id, stream.headers, stream.body)
    send(stream.client, {:push_promise, response})
    {:next_state, @reserved_remote, stream}
  end

  def recv(from, %Continuation{} = frame, _state, %{ref: ref} = stream) do
    {:ok, headers} = Hpack.decode(ref, frame.header_block_fragment)

    :gen_statem.reply(from, :ok)

    stream = %Stream{stream | headers: stream.headers ++ headers}
    {:keep_state, stream}
  end

  def recv(frame, state, stream) do
    """
    Unknown RECV on stream #{stream.id}
    Frame: #{inspect(frame)}
    State: #{inspect(state)}
    """
    |> Logger.info()

    {:keep_state, stream}
  end

  # Enter Events

  def handle_event(:enter, _old, @hc_remote, %{socket: socket} = stream) do
    bin = stream.id |> RstStream.new() |> Encodable.to_bin()
    Socket.send(socket, bin)

    :gen_statem.cast(self(), :close)
    {:keep_state, stream}
  end

  def handle_event(:enter, _old, @closed, stream) do
    response = Response.new(stream.id, stream.headers, stream.body)
    Tasks.run(stream.on_response, response)
    send(stream.client, {:end_stream, response})

    {:stop, {:shutdown, {:finished, stream.id}}}
  end

  def handle_event(:enter, _old, _new, stream), do: {:keep_state, stream}

  # For SETTINGS initial_window_size and max_frame_size changes
  def handle_event(:info, {:settings_change, window, max_frame}, _, stream) do
    flow =
      stream.flow
      |> Stream.FlowControl.increment_window(window)
      |> Stream.FlowControl.set_max_frame_size(max_frame)

    {:keep_state, %{stream | flow: flow}}
  end

  # Casts

  def handle_event(:cast, :close, _state, stream) do
    {:next_state, @closed, stream}
  end

  def handle_event(:cast, {:recv, frame}, state, stream) do
    recv(frame, state, stream)
  end

  def handle_event(:cast, msg, state, stream) do
    """
    === Unknown cast ===
    #{inspect(msg)}
    State: #{inspect(state)}
    Stream: #{inspect(stream)}
    """
    |> Logger.info()

    {:keep_state, stream}
  end

  # Calls

  def handle_event({:call, from}, {:recv, frame}, state, stream) do
    recv(from, frame, state, stream)
  end

  def handle_event({:call, from}, {:send_headers, request}, _state, stream) do
    %{headers: headers, body: payload, on_response: on_resp} = request

    {:ok, encoded} = Hpack.encode(stream.ref, headers)
    headers_payload = :erlang.iolist_to_binary(encoded)

    bin =
      %Frame.Headers{
        stream_id: stream.id,
        header_block_fragment: headers_payload,
        end_stream: is_nil(payload),
        end_headers: true
      }
      |> Encodable.to_bin()

    Socket.send(stream.socket, bin)
    # Logger.info("Sending, Stream ID: #{stream.id}, size: #{byte_size(h)}")

    # Reply early for better performance
    :gen_statem.reply(from, :ok)

    flow =
      if payload do
        stream.flow
        |> Stream.FlowControl.add(payload)
        |> Stream.FlowControl.process()
        |> send_data_frames(stream.socket, stream.id)
      else
        stream.flow
      end

    stream = %{stream | flow: flow, on_response: on_resp}

    {:next_state, @open, stream}
  end

  def send_data_frames(flow_control, socket, stream_id) do
    flow_control.out_queue
    |> :queue.to_list()
    |> Enum.each(fn {data, end_stream?} ->
      send_data_frame(socket, stream_id, end_stream?, data)
    end)

    %{flow_control | out_queue: :queue.new()}
  end

  defp send_data_frame(socket, stream_id, end_stream?, data) do
    bin =
      %Frame.Data{stream_id: stream_id, end_stream: end_stream?, data: data}
      |> Encodable.to_bin()

    Socket.send(socket, bin)
  end

  # Other Callbacks

  def init(stream), do: {:ok, @idle, stream}

  def callback_mode, do: [:handle_event_function, :state_enter]

  def terminate(_reason, _state, _data), do: :void

  def code_change(_vsn, state, data, _extra), do: {:ok, state, data}
end
