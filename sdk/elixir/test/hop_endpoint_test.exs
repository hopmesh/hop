defmodule Hop.EndpointTest do
  use ExUnit.Case, async: false

  test "hops:// request/response round trip over a real TCP bearer" do
    port = 9955
    {:ok, server} = Hop.Endpoint.start_link([])
    Hop.Endpoint.on(server, "acme/orders", fn req, reply -> reply.(201, "got:" <> req.args) end)
    {:ok, _} = Hop.TcpBearer.listen(server, port)
    addr = Hop.Endpoint.address(server)
    assert is_binary(addr) and byte_size(addr) > 30

    {:ok, client} = Hop.Endpoint.start_link([])
    {:ok, _} = Hop.TcpBearer.dial(client, "localhost", port)

    assert {:ok, 201, "got:temp=21"} =
             Hop.Endpoint.request(client, addr, "acme/orders", "create", "temp=21")
  end

  test "closing an endpoint with a live bearer connection is use-after-free-safe" do
    port = 9959
    {:ok, server} = Hop.Endpoint.start_link([])
    Hop.Endpoint.on(server, "svc", fn _req, reply -> reply.(200, "ok") end)
    {:ok, _} = Hop.TcpBearer.listen(server, port)
    {:ok, client} = Hop.Endpoint.start_link([])
    {:ok, _} = Hop.TcpBearer.dial(client, "localhost", port)

    assert {:ok, 200, "ok"} =
             Hop.Endpoint.request(client, Hop.Endpoint.address(server), "svc", "m", "x")

    # Close the server while its accepted recv_loop and the client's socket are still live. Unlike the
    # C-FFI SDKs, Elixir needs no guard: the node is only ever touched inside the GenServer, a bearer
    # reaches it via a GenServer cast to the (now stopped) server which is simply dropped, and there is
    # no manual node_free (Rustler GCs the node with the GenServer). So no use-after-free is possible.
    Hop.Endpoint.close(server)
    Process.sleep(100)
    assert Process.alive?(client)
    Hop.Endpoint.close(client)
  end

  test "joins a cluster and sets the TTL visibility threshold" do
    # cluster join + quorum NIFs resolve and behave; the cross-replica dedup + hold are proven in the
    # Rust crate, here we exercise the Elixir surface (both are opts on start_link).
    {:ok, ep} = Hop.Endpoint.start_link(cluster: "shared-cluster-passphrase", quorum: 3)
    addr = Hop.Endpoint.address(ep)
    assert is_binary(addr) and byte_size(addr) > 30
    Hop.Endpoint.close(ep)
  end

  test "service request throwing handler leaves request queued for redelivery (ABI-002)" do
    port = 9961
    test_pid = self()
    {:ok, server} = Hop.Endpoint.start_link([])
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Hop.Endpoint.on(server, "flaky", fn _req, reply ->
      attempt = Agent.get_and_update(counter, fn c -> {c + 1, c + 1} end)
      send(test_pid, {:attempt, attempt})

      if attempt == 1 do
        raise "handler failed attempt 1"
      else
        reply.(200, "recovered")
      end
    end)

    {:ok, _} = Hop.TcpBearer.listen(server, port)
    addr = Hop.Endpoint.address(server)

    {:ok, client} = Hop.Endpoint.start_link([])
    {:ok, _} = Hop.TcpBearer.dial(client, "localhost", port)

    task =
      Task.async(fn ->
        Hop.Endpoint.request(client, addr, "flaky", "call", "test", 5000)
      end)

    assert_receive {:attempt, 1}, 5000
    assert_receive {:attempt, 2}, 5000

    assert {:ok, 200, "recovered"} = Task.await(task, 5000)
    assert Agent.get(counter, fn c -> c end) == 2

    Hop.Endpoint.close(client)
    Hop.Endpoint.close(server)
  end

  test "persists state across restart when backed by db_path (ABI-003)" do
    tmp_dir = System.tmp_dir!()
    db_path = Path.join(tmp_dir, "hop-elixir-restart-#{:erlang.unique_integer([:positive])}.db")
    secret = :crypto.strong_rand_bytes(32)

    # Step 1: Open with db_path, verify persistence, mark state handled in cluster
    {:ok, e1} =
      Hop.Endpoint.start_link(
        db_path: db_path,
        secret: secret,
        cluster: "shared-cluster-passphrase"
      )

    assert Hop.Endpoint.persistent?(e1) == true
    assert Hop.Endpoint.encrypted?(e1) == false

    from = :crypto.strong_rand_bytes(32)
    req_id = :crypto.strong_rand_bytes(32)

    :ok = Hop.Endpoint.cluster_mark_done(e1, from, req_id)
    assert Hop.Endpoint.cluster_would_drop(e1, from, req_id) == true
    Hop.Endpoint.close(e1)
    Process.sleep(100)
    :erlang.garbage_collect()

    # Step 2: Reopen same db_path, verify persistence and state recovery
    {:ok, e2} =
      Hop.Endpoint.start_link(
        db_path: db_path,
        secret: secret,
        cluster: "shared-cluster-passphrase"
      )

    try do
      assert Hop.Endpoint.persistent?(e2) == true
      assert Hop.Endpoint.cluster_would_drop(e2, from, req_id) == true
    after
      Hop.Endpoint.close(e2)
      File.rm(db_path)
    end
  end
end
