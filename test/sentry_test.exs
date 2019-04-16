defmodule SentryTest do
  use ExUnit.Case
  import ExUnit.CaptureLog
  import Sentry.TestEnvironmentHelper

  test "excludes events properly" do
    bypass = Bypass.open()

    Bypass.expect(bypass, fn conn ->
      opts = Plug.Parsers.init([parsers: [Sentry.Plug.Parsers.GzipJSON, :json], json_decoder: Jason])
      conn = Plug.Parsers.call(conn, opts)
      assert conn.body =~ "RuntimeError"
      assert conn.request_path == "/api/1/store/"
      assert conn.method == "POST"
      Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
    end)

    modify_env(
      :sentry,
      filter: Sentry.TestFilter,
      dsn: "http://public:secret@localhost:#{bypass.port}/1",
      client: Sentry.Client
    )

    assert {:ok, _} =
             Sentry.capture_exception(
               %RuntimeError{message: "error"},
               event_source: :plug,
               result: :sync
             )

    assert :excluded =
             Sentry.capture_exception(
               %ArithmeticError{message: "error"},
               event_source: :plug,
               result: :sync
             )

    assert {:ok, _} =
             Sentry.capture_message("RuntimeError: error", event_source: :plug, result: :sync)
  end

  test "errors when taking too long to receive response" do
    bypass = Bypass.open()

    Bypass.expect(bypass, fn conn ->
      :timer.sleep(100)
      assert conn.request_path == "/api/1/store/"
      assert conn.method == "POST"
      Plug.Conn.send_resp(conn, 200, ~s<{"id": "340"}>)
    end)

    modify_env(
      :sentry,
      filter: Sentry.TestFilter,
      dsn: "http://public:secret@localhost:#{bypass.port}/1"
    )

    assert capture_log(fn ->
             assert :error = Sentry.capture_message("error", [])
           end) =~ "Failed to send Sentry event"

    Bypass.pass(bypass)
  end

  test "handles three element tuple as stacktrace" do
    bypass = Bypass.open()

    Bypass.expect(bypass, fn conn ->
      assert conn.request_path == "/api/1/store/"
      assert conn.method == "POST"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      {:ok, json} = Jason.decode(body)
      assert json["culprit"] == "GenServer.call/3"
      assert List.first(json["exception"])["value"] == "Erlang error: :timeout"
      Plug.Conn.send_resp(conn, 200, ~s<{"id": "340"}>)
    end)

    modify_env(
      :sentry,
      dsn: "http://public:secret@localhost:#{bypass.port}/1"
    )

    Process.flag(:trap_exit, true)

    {:ok, pid} = Sentry.TestGenServer.start_link(self())
    spawn_pid = spawn_link(fn -> GenServer.call(pid, {:sleep, 100}, 0) end)

    receive do
      {:EXIT, ^spawn_pid, {reason, stack}} ->
        Sentry.capture_exception(reason, stacktrace: stack)
    end

    Bypass.pass(bypass)
  end
end
