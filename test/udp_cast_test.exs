defmodule UdpCastTest do
  use ExUnit.Case

  test "broadcast" do
    broadcast_group =
      for idx <- 1..5 do
        start_udpcast_server(
          :"test_server_#{idx}",
          %UdpCast.Args.Broadcast{
            on_cast: forward_cast_to_self()
          }
        )
      end

    msg = make_ref()
    assert :ok = UdpCast.cast(hd(broadcast_group), msg)

    for server <- broadcast_group do
      assert_receive {^server, ^msg}
    end
  end

  test "multicast" do
    multicast_group_1 =
      for idx <- 1..3 do
        start_udpcast_server(
          :"test_server_1_#{idx}",
          %UdpCast.Args.Multicast{
            multicast_addr: {233, 252, 1, 40},
            port: 40_001,
            on_cast: forward_cast_to_self()
          }
        )
      end

    multicast_group_2 =
      for idx <- 1..3 do
        start_udpcast_server(
          :"test_server_2_#{idx}",
          %UdpCast.Args.Multicast{
            multicast_addr: {233, 252, 1, 50},
            port: 40_002,
            on_cast: forward_cast_to_self()
          }
        )
      end

    msg = make_ref()
    assert :ok = UdpCast.cast(hd(multicast_group_1), msg)

    for server <- multicast_group_1 do
      assert_receive {^server, ^msg}
    end

    refute_receive _

    msg = make_ref()
    assert :ok = UdpCast.cast(hd(multicast_group_2), msg)

    for server <- multicast_group_2 do
      assert_receive {^server, ^msg}
    end

    refute_receive _
  end

  defp start_udpcast_server(id, args) do
    child_spec = Supervisor.child_spec({UdpCast, args}, id: id)
    start_supervised!(child_spec)
  end

  defp forward_cast_to_self do
    test_pid = self()

    fn msg ->
      send(test_pid, {self(), msg})
      :ok
    end
  end
end
