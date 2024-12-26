defmodule UdpCast do
  @moduledoc ~S"""
  A GenServer implementation for UDP broadcast and multicast communication.

  This module provides functionality for:
  - UDP broadcast messaging across a network
  - UDP multicast group messaging
  - Customizable message handling via callback functions

  ## Examples

      # Start a UDP broadcast server
      {:ok, pid} = UdpCast.start_link(%UdpCast.Args.Broadcast{
        on_cast: fn msg ->
          IO.puts("Received: #{inspect(msg)}")
          :ok
        end
      })
  """

  use GenServer
  require Logger

  @typedoc """
  Callback function for handling received UDP messages.
  Takes the multi/broad-casted message and returns `:ok`.
  """
  @type on_cast :: (msg :: term() -> :ok)

  defmodule State do
    @moduledoc false

    @enforce_keys [:socket, :addr, :port, :on_cast]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            socket: :gen_udp.socket(),
            addr: :inet.ip_address(),
            port: :inet.port_number(),
            on_cast: UdpCast.on_cast()
          }
  end

  defmodule Args do
    @moduledoc """
    Configuration arguments for UDP communication.
    Contains submodules for Broadcast and Multicast configurations.
    """

    defmodule Broadcast do
      @moduledoc """
      Configuration for UDP broadcast communication.
      """

      @enforce_keys [:on_cast]
      defstruct @enforce_keys ++
                  [
                    bind_addr: {0, 0, 0, 0},
                    port: 45_892
                  ]

      @typedoc """
      - `:bind_addr` - Local IP address to bind to (default: {0,0,0,0})
      - `:port` - UDP port number for sending/receiving broadcasts (default: 45892)
      - `:on_cast` - Callback function for handling received messages
      """
      @type t :: %__MODULE__{
              bind_addr: :inet.ip_address(),
              port: :inet.port_number(),
              on_cast: UdpCast.on_cast()
            }
    end

    defmodule Multicast do
      @moduledoc """
      Configuration for UDP multicast group communication.
      """

      @enforce_keys [:on_cast]
      defstruct @enforce_keys ++
                  [
                    bind_addr: {0, 0, 0, 0},
                    port: 45_892,
                    multicast_addr: {233, 252, 1, 32},
                    multicast_ttl: 1,
                    multicast_if: nil
                  ]

      @typedoc """
      - `:bind_addr` - Local IP address to bind to (default: {0,0,0,0})
      - `:port` - UDP port number for sending/receiving multicast messages (default: 45892)
      - `:multicast_addr` - Multicast group IP address (default: {233,252,1,32})
      - `:multicast_if` - Local interface for multicast (default: nil)
      - `:multicast_ttl` - Time-to-live for multicast packets (default: 1)
      - `:on_cast` - Callback function for handling received messages
      """
      @type t :: %__MODULE__{
              bind_addr: :inet.ip_address(),
              port: :inet.port_number(),
              multicast_addr: :inet.ip_address(),
              multicast_if: nil | :gen_udp.multicast_if(),
              multicast_ttl: non_neg_integer(),
              on_cast: UdpCast.on_cast()
            }
    end

    @type t :: Broadcast.t() | Multicast.t()
  end

  @sol_socket 0xFFFF
  @so_reuseport 0x0200
  @bcast_header <<"uc::">>

  @doc """
  Starts a new `#{inspect(__MODULE__)}` process with the given configuration arguments.
  """
  @spec start_link(Args.t()) :: GenServer.on_start()
  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  @doc """
  Sends a broadcaste/multicast message.

  ## Parameters
  - `server`: The `#{inspect(__MODULE__)}` process to send the message to.
  - `msg`: The message to be sent.

  ## Returns
  - `:ok` if the message was successfully sent.
  - `{:error, reason}` if there was an error sending the message.
  """
  @spec cast(GenServer.server(), msg :: term()) :: :ok | {:error, reason :: term()}
  def cast(server, msg) do
    GenServer.call(server, {:cast, msg})
  end

  @impl true
  def init(args) do
    {addr, port, open_options} = socket_options(args)

    case :gen_udp.open(port, open_options) do
      {:ok, socket} ->
        Logger.info("Started #{__MODULE__} with args: #{inspect(args)}")
        {:ok, %State{socket: socket, addr: addr, port: port, on_cast: args.on_cast}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:cast, msg}, _from, %State{socket: socket, addr: addr, port: port} = state) do
    packet = [@bcast_header, :erlang.term_to_binary(msg)]
    res = :gen_udp.send(socket, addr, port, packet)
    {:reply, res, state}
  end

  @impl true
  def handle_info(
        {:udp, _socket, _ip, _port, <<@bcast_header, packet::binary>>},
        %State{} = state
      ) do
    try do
      # using unsafe binary_to_term
      :erlang.binary_to_term(packet)
    rescue
      # coveralls-ignore-start
      ArgumentError ->
        Logger.info("Malformed packet received")
        # coveralls-ignore-stop
    else
      msg ->
        Logger.info("Received cast: #{inspect(msg)}")
        state.on_cast.(msg)
    end

    {:noreply, state}
  end

  # coveralls-ignore-start

  def handle_info({:udp, _socket, _ip, _port, _} = u, state) do
    Logger.info("Unknown UDP packet received: #{inspect(u)}")
    {:noreply, state}
  end

  # coveralls-ignore-stop

  @spec socket_options(Args.t()) ::
          {
            addr :: :inet.ip_address(),
            port :: :inet.port_number(),
            [:gen_udp.open_option()]
          }
  defp socket_options(options) do
    {cast_options, cast_addr} =
      case options do
        %Args.Broadcast{} ->
          {[], {255, 255, 255, 255}}

        %Args.Multicast{multicast_if: multicast_if} when multicast_if != nil ->
          {
            [
              multicast_loop: true,
              multicast_if: options.multicast_if,
              multicast_ttl: options.ttl,
              add_membership: {options.multicast_addr, options.multicast_if}
            ],
            options.multicast_addr
          }

        %Args.Multicast{} ->
          {
            [
              multicast_loop: true,
              multicast_ttl: options.multicast_ttl,
              add_membership: {options.multicast_addr, {0, 0, 0, 0}}
            ],
            options.multicast_addr
          }
      end

    open_options =
      [:binary, active: true, ip: options.bind_addr, reuseaddr: true, broadcast: true] ++
        cast_options ++ reuse_port()

    {cast_addr, options.port, open_options}
  end

  @spec reuse_port :: [:gen_udp.open_option()]
  defp reuse_port do
    case :os.type() do
      {:unix, os_name} ->
        if os_name in [:darwin, :freebsd, :openbsd, :linux, :netbsd] do
          [{:raw, @sol_socket, @so_reuseport, <<1::native-32>>}]
        else
          []
        end

      # coveralls-ignore-start
      _ ->
        []
        # coveralls-ignore-stop
    end
  end
end
