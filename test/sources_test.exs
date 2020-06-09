defmodule Sentry.SourcesTest do
  use ExUnit.Case
  use Plug.Test
  import Sentry.TestEnvironmentHelper

  test "exception makes call to Sentry API" do
    correct_context = %{
      "context_line" => "      raise RuntimeError, \"Error\"",
      "post_context" => ["    end", "", "    post \"/error_route\" do"],
      "pre_context" => ["", "    get \"/error_route\" do", "      _ = conn"]
    }

    bypass = Bypass.open()

    Bypass.expect(bypass, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      frames =
        Jason.decode!(body)
        |> get_in(["stacktrace", "frames"])
        |> Enum.reverse()

      assert ^correct_context =
               Enum.at(frames, 0)
               |> Map.take(["context_line", "post_context", "pre_context"])

      assert body =~ "RuntimeError"
      assert body =~ "DefaultConfig"
      assert conn.request_path == "/api/1/store/"
      assert conn.method == "POST"
      Plug.Conn.resp(conn, 200, ~s<{"id": "340"}>)
    end)

    modify_env(:sentry, dsn: "http://public:secret@localhost:#{bypass.port}/1")

    assert_raise(Plug.Conn.WrapperError, "** (RuntimeError) Error", fn ->
      conn(:get, "/error_route")
      |> Sentry.TestPlugApplications.DefaultConfig.call([])
    end)
  end
end
