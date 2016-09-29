defmodule Kadabra.Http2 do
  @moduledoc """
    Handles all HTTP2 connection, request and response functions.
  """
  require Logger

  alias Kadabra.{Hpack}

  def connect(uri, mode, cert, key) do
    options = [cert,
               key,
               {:password, ''},
               {:packet, 0},
               {:reuseaddr, false},
               {:active, true},
               :binary]
    :ssl.start
    case :ssl.connect(uri, 443, options, 3000) do
      {:ok, ssl_socket} -> {:ok, ssl_socket}
      {:error, reason} -> {:error, reason}
    end
  end

  def send_connection_preface(socket) do
    :ssl.send(socket, connection_preface)
    do_receive_once socket
  end

  def status_code(<<1::1, status::7, _rest::binary>>) do
    case status do
      8 -> 200
      9 -> 204
      10 -> 206
      11 -> 304
      12 -> 400
      13 -> 404
      14 -> 500
      _ -> status
    end
  end
  def status_code(payload), do: payload

  def establish_connection(socket) do
    {:ok, data} = send_settings(socket)
    if data == build_frame(0x04, 0x01, 0, <<>>) do
      send_ack(socket)
    else
      {:error, "Can't establish a connection."}
    end
  end

  defp send_settings sock do
    :ssl.send(sock, settings_frame)
    do_receive_once sock
  end

  defp send_ack sock do
    :ssl.send(sock, settings_ack_frame)
  end

  defp do_receive_once _socket do
    receive do
      {:ssl, _socket, bin} ->
        frame = bin |> parse_frame
        parse_frame_type(frame, bin)
      {:ssl_closed, _socket} ->
        Logger.error "SSL closed"
        {:error, "closed."}
      {:ssl_error, _socket, reason} ->
        Logger.error "SSL error: #{inspect(reason)}"
        {:error, reason}
    after
      5000 ->
        {:error, "timeout."}
    end
  end

  def wait_response _socket do
    receive do
      {:ssl, socket, bin} ->
        case wait_payload(socket) do
          {:ok, payload} ->
            {header, data} = order_data(bin, payload)
            {header, data} |> inspect |> Logger.debug
            {:ok, header, data}
          error ->
            error
        end
      {:ssl_closed, _socket} ->
        {:error, "closed."}
      {:ssl_error, _socket, reason} ->
        {:error, reason}
    after
      5000 ->
        {:error, "timeout."}
    end
  end

  defp wait_payload _socket do
    receive do
      {:ssl, _socket, bin} ->
        {:ok, bin}
      {:ssl_closed, _socket} ->
        {:error, "closed."}
      {:ssl_error, _socket, reason} ->
        {:error, reason}
    after
      5000 ->
        {:error, "timeout."}
    end
  end

  def order_data(first, second) do
    cond do
      header_frame?(first) -> {first, second}
      header_frame?(second) -> {second, first}
      true -> {first, second}
    end
  end

  defp header_frame?(bin) do
    frame = parse_frame(bin)
    frame[:frame_type] == 0x1
  end

  def parse_frame_type(frame, bin) do
    case frame[:frame_type] do
      0x0 ->
        Logger.debug "Got data frame..."
        {:ok, frame}
      0x1 ->
        Logger.debug "Got header frame..."
        IO.inspect frame
        {:ok, frame}
      0x2 ->
        Logger.debug "Got priority frame..."
        {:ok, frame}
      0x3 ->
        <<error_code::32, _::binary>> = frame[:payload]
        {:error, "RST_STREAM error_code:#{error_code}"}
      0x7 ->
        <<error_code::32, _::binary>> = frame[:payload]
        {:error, "GOAWAY error_code:#{error_code}"}
      _ ->
        {:ok, bin}
    end
  end

  def parse_frame(<<payload_size::24, frame_type::8, flags::8, 0::1,
    stream_id::31, payload::binary>>) do

    %{
      payload_size: payload_size,
      frame_type: frame_type,
      flags: flags,
      stream_id: stream_id,
      payload: payload
    }
  end
  def parse_frame(bin), do: bin

  def connection_preface, do: "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
  def settings_frame, do: build_frame(0x4, 0, 0, <<>>)
  def settings_ack_frame, do: build_frame(0x04, 0x01, 0, <<>>)
  def ack_frame, do: build_frame(0x01, 0, 0, <<>>)
  def ping_frame, do: build_frame(0x6, 0x0, 0, <<1::64>>)

  def goaway_frame do
    no_error = 0
    build_frame(0x7, 0x0, 0, <<0::31, 1::1, no_error::32>>)
  end

  # def push_header_frame(stream, mode, notification) do
  #   end_headers = 0x4
  #   payload_size =
  #     notification.payload
  #     |> json_payload
  #     |> byte_size
  #     |> to_string
  #   headers = <<post_header::bitstring,
  #     https_header::bitstring,
  #     encode_header(":path", "/3/device/#{notification.device_token}")::bitstring,
  #     encode_header("host", uri)::bitstring,
  #     encode_header("apns-topic", notification.topic)::bitstring,
  #     encode_header("content-length", payload_size)::bitstring>>

  #   unless notification.expiration == nil do
  #     headers = headers <> encode_header("apns-expiration", notification.expiration)
  #   end

  #   build_frame(0x1, end_headers, stream, headers)
  # end

  def post_header, do: <<1::1, 0::1, 0::1, 0::1, 0::1, 0::1, 1::1, 1::1>>
  def https_header, do: <<1::1, 0::1, 0::1, 0::1, 0::1, 1::1, 1::1, 1::1>>

  def encode_header(header, value) do
    <<0::1, 0::1, 0::1, 1::1, 0::4, 0::1, byte_size(header)::7>>
    <> header
    <> <<0::1, byte_size(value)::7>>
    <> value
  end

  #def decode_headers(bin) do
  #  {header, rest} =
  #    case bin do
  #    <<1::, index::7, rest::bitstring>> ->
  #      {indexed_header(index), rest}
  #  end
  #  [header] ++ decode_headers(rest)
  #end

  #def indexed_header(index)
  #  Dos.Hpack.static_header(index)
  #end

  def decode_headers(<<>>), do: []
  def decode_headers(<<1::1, index::7, rest::bitstring>>) do # Indexed Header
    header = Hpack.static_header(index)
    Logger.info("Indexed, #{inspect(header)}")
    [header] ++ decode_headers(rest)
  end
  def decode_headers(<<0::1, 1::1, index::6, h::1, value_size::7, rest::bitstring>>) do # Literal header, incremental indexing
    value_size = value_size*4
    <<value::size(value_size), rest:: bitstring>> = rest
    Logger.info("Literal, Inc Indexing, H: #{h}, #{inspect(value)}")
    [{index, value}] ++ decode_headers(rest)
  end
  def decode_headers(<<0::4, index::4, h::1, value_size::7, rest::bitstring>>) do # Literal header without indexing -- Indexed Name
    value_size = value_size*4
    <<value::size(value_size), rest:: bitstring>> = rest
    Logger.info("Literal without Indexing, Indexed Name, H: #{h}, #{inspect(value)}")
    [{index, value}] ++ decode_headers(rest)
  end
  def decode_headers(<<0::1, 0::1, 0::1, 1::1, index::4, h::1, value_size::7, rest::bitstring>>) do # Literal header, never indexed
    value_size = value_size*4
    <<value::size(value_size), rest:: bitstring>> = rest
    Logger.info("Literal, Never Indexed, H: #{h}, #{inspect(value)}")
    [{index, value}] ++ decode_headers(rest)
  end
  def decode_headers(<<0::1, 0::1, 0::1, 1::1, 0::4, h::1, size::7, rest::bitstring>> = bin) do # Literal header no indexing
    header_size = size*4
    <<header::size(header_size), 0::1, size::7, rest::bitstring>> = rest
    value_size = size*4
    <<value::size(value_size), rest::bitstring>> = rest
    Logger.info("Literal, No Indexing, H: #{h}, #{inspect(value)}")
    [{header, value}] ++ decode_headers(rest)
  end
  def decode_headers(<<0::1, 0::1, 1::1, max_size::5, rest::bitstring>>) do # Dynamic table size update
    Logger.info("Dynamic table size update, max: #{max_size}")
    [] ++ decode_headers(rest)
  end

  def push_data_frame(stream, payload) do
    build_frame(0x0, 0x1, stream, payload)
  end

  def build_frame(frame_type, flags, stream_id, payload) do
    header = <<byte_size(payload)::24, frame_type::8, flags::8, 0::1, stream_id::31>>
    <<header::bitstring, payload::bitstring>>
  end
end
