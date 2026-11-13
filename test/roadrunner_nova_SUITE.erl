-module(roadrunner_nova_SUITE).
-moduledoc """
`roadrunner_nova` over real connections: what Nova's code does through
`nova_req` (interim and streamed responses, cookies, files, compression,
body and multipart reads and their errors), Nova's own body plugins, and
the listener lifecycle (TLS, listeners Nova names with tuples, draining).

Most cases drive `roadrunner_nova_test_plugin`, a plugin that calls
`nova_req` for the route's `action` and stops Nova's pipeline.
""".

-behaviour(ct_suite).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([suite/0, all/0, init_per_suite/1, end_per_suite/1]).
-export([unreachable/1, uploaded/1, decoded/1]).
-export([
    nothing_sent_is_204/1,
    inform_goes_before_the_response/1,
    streams_body_events_and_trailers/1,
    binary_status/1,
    sendfile_sends_the_range/1,
    sendfile_keeps_its_content_length/1,
    no_cookie_when_the_session_exists/1,
    response_cookie_and_headers/1,
    compresses_when_asked/1,
    reads_the_body_in_pieces/1,
    body_read_timeout/1,
    body_over_the_cap/1,
    malformed_chunked_body/1,
    reads_multipart_parts/1,
    malformed_multipart/1,
    multipart_part_cut_short/1,
    multipart_read_timeout/1,
    nova_multipart_plugin_uploads/1,
    nova_request_plugin_decodes_json/1,
    listener_without_compression/1,
    tls_listener/1,
    deprecated_tls_options/1,
    drains_listeners/1
]).

-define(PLUGIN, roadrunner_nova_test_plugin).

suite() ->
    [{timetrap, {seconds, 60}}].

all() ->
    [
        nothing_sent_is_204,
        inform_goes_before_the_response,
        streams_body_events_and_trailers,
        binary_status,
        sendfile_sends_the_range,
        sendfile_keeps_its_content_length,
        no_cookie_when_the_session_exists,
        response_cookie_and_headers,
        compresses_when_asked,
        reads_the_body_in_pieces,
        body_read_timeout,
        body_over_the_cap,
        malformed_chunked_body,
        reads_multipart_parts,
        malformed_multipart,
        multipart_part_cut_short,
        multipart_read_timeout,
        nova_multipart_plugin_uploads,
        nova_request_plugin_decodes_json,
        listener_without_compression,
        tls_listener,
        deprecated_tls_options,
        drains_listeners
    ].

init_per_suite(Config) ->
    Port = free_port(),
    ok = application:load(nova),
    ok = application:set_env(nova, bootstrap_application, nova_test_app),
    ok = application:set_env(nova, server, roadrunner_nova),
    ok = application:set_env(nova, cowboy_configuration, #{
        port => Port,
        roadrunner => #{request_timeout => 1000, max_content_length => 1000000}
    }),
    ok = application:set_env(nova, environment, test),
    ok = application:set_env(nova, plugins, []),
    persistent_term:put(nova_test_app_plugin, counters:new(2, [write_concurrency])),
    {ok, _} = application:ensure_all_started(nova_test_app),
    {ok, _} = application:ensure_all_started(inets),
    File = filename:join(?config(priv_dir, Config), "file.txt"),
    ok = file:write_file(File, ~"0123456789"),
    ok = nova_router:add_routes(roadrunner_nova_test, routes(File)),
    [{port, Port} | Config].

end_per_suite(_Config) ->
    persistent_term:erase(nova_test_app_plugin),
    ok = application:stop(nova_test_app),
    ok = application:stop(nova).

routes(File) ->
    Actions = [
        nothing, inform, stream, binary_status, cookie, big, read_body, read_parts
    ],
    [plugin_route(Action, #{action => Action}) || Action <- Actions] ++
        [
            plugin_route(sendfile, #{action => sendfile, file => File}),
            plugin_route(sendfile_sized, #{action => sendfile_sized, file => File}),
            #{
                plugins => [
                    {pre_request, nova_multipart_plugin, #{
                        handler => {nova_multipart_memory_handler, #{}}
                    }}
                ],
                routes => [{"/upload", fun ?MODULE:uploaded/1, #{methods => [post]}}]
            },
            #{
                plugins => [{pre_request, nova_request_plugin, #{decode_json_body => true}}],
                routes => [{"/json", fun ?MODULE:decoded/1, #{methods => [post]}}]
            }
        ].

plugin_route(Action, Options) ->
    #{
        plugins => [{pre_request, ?PLUGIN, Options}],
        routes => [
            {"/" ++ atom_to_list(Action), fun ?MODULE:unreachable/1, #{methods => [get, post]}}
        ]
    }.

%% The plugins stop the pipeline before the controller.
unreachable(_Req) ->
    {status, 500}.

uploaded(#{params := Params, files := Files}) ->
    {json, #{params => Params, files => length(Files)}}.

decoded(#{json := Json}) ->
    {json, Json}.

%% =============================================================================
%% Responses
%% =============================================================================

nothing_sent_is_204(Config) ->
    ?assertMatch({204, _, <<>>}, request(Config, ~"GET /nothing HTTP/1.1\r\n", <<>>)).

inform_goes_before_the_response(Config) ->
    Raw = raw(Config, [~"GET /inform HTTP/1.1\r\n", headers(), ~"\r\n"]),
    ?assertMatch(<<"HTTP/1.1 103 ", _/binary>>, Raw),
    {match, _} = re:run(Raw, "(?i)\r\nlink: </a.css>; rel=preload\r\n"),
    {match, _} = re:run(Raw, "HTTP/1.1 200 [^\r]*\r\n(.|\r\n)*after hints$").

streams_body_events_and_trailers(Config) ->
    {200, _, Body} = request(Config, ~"GET /stream HTTP/1.1\r\nte: trailers\r\n", <<>>),
    {match, _} = re:run(Body, "body-"),
    {match, _} = re:run(Body, "data: one\n\n"),
    {match, _} = re:run(Body, "data: two\n\n"),
    {match, _} = re:run(Body, "(?i)x-sum: 1").

binary_status(Config) ->
    ?assertMatch({201, _, ~"made"}, request(Config, ~"GET /binary_status HTTP/1.1\r\n", <<>>)).

sendfile_sends_the_range(Config) ->
    {200, Headers, Body} = request(Config, ~"GET /sendfile HTTP/1.1\r\n", <<>>),
    ?assertEqual(~"123", Body),
    {match, _} = re:run(Headers, "(?i)\r\ncontent-length: 3\r\n").

sendfile_keeps_its_content_length(Config) ->
    {200, Headers, ~"123"} = request(Config, ~"GET /sendfile_sized HTTP/1.1\r\n", <<>>),
    ?assertMatch({match, [_]}, re:run(Headers, "(?i)\r\ncontent-length:", [global])).

no_cookie_when_the_session_exists(Config) ->
    %% A request with a session gets no new session cookie.
    {201, Headers, ~"made"} = request(
        Config, ~"GET /binary_status HTTP/1.1\r\ncookie: session_id=abc\r\n", <<>>
    ),
    ?assertEqual(nomatch, re:run(Headers, "(?i)set-cookie")).

response_cookie_and_headers(Config) ->
    {200, Headers, Body} = request(Config, ~"GET /cookie HTTP/1.1\r\n", <<>>),
    ?assertEqual(~"with cookie", Body),
    {match, _} = re:run(Headers, "(?i)\r\nset-cookie: a=1"),
    {match, _} = re:run(Headers, "(?i)\r\nx-set: v\r\n").

compresses_when_asked(Config) ->
    {200, Headers, Body} = request(
        Config, ~"GET /big HTTP/1.1\r\naccept-encoding: gzip\r\n", <<>>
    ),
    {match, _} = re:run(Headers, "(?i)\r\ncontent-encoding: gzip\r\n"),
    ?assertEqual(binary:copy(~"a", 4096), zlib:gunzip(Body)).

%% =============================================================================
%% Reading the body
%% =============================================================================

reads_the_body_in_pieces(Config) ->
    ?assertMatch(
        {200, _, ~"0123456789"},
        request(Config, ~"POST /read_body HTTP/1.1\r\ncontent-length: 10\r\n", ~"0123456789")
    ).

body_read_timeout(Config) ->
    ?assertMatch(
        {400, _, ~"timeout"},
        request(Config, ~"POST /read_body HTTP/1.1\r\ncontent-length: 100\r\n", ~"part")
    ).

body_over_the_cap(Config) ->
    ?assertMatch(
        {400, _, ~"payload_too_large"},
        request(Config, ~"POST /read_body HTTP/1.1\r\ncontent-length: 2000000\r\n", <<>>)
    ).

malformed_chunked_body(Config) ->
    {400, _, Reason} = request(
        Config, ~"POST /read_body HTTP/1.1\r\ntransfer-encoding: chunked\r\n", ~"zz\r\n"
    ),
    ?assertNotEqual(~"timeout", Reason).

reads_multipart_parts(Config) ->
    Body = <<
        "--B\r\nx-name: a\r\n\r\nhello\r\n",
        "--B\r\nx-name: b\r\n\r\nworld!\r\n--B--\r\n"
    >>,
    ?assertMatch(
        {200, _, ~"a=hello;b=world!;"},
        request(Config, multipart_head(~"/read_parts", byte_size(Body)), Body)
    ).

malformed_multipart(Config) ->
    ?assertMatch(
        {400, _, ~"{multipart,no_initial_boundary}"},
        request(Config, multipart_head(~"/read_parts", 7), ~"garbage")
    ).

multipart_part_cut_short(Config) ->
    %% The body ends inside a part: its body read fails.
    Body = <<"--B\r\nx-name: a\r\n\r\ncut short">>,
    ?assertMatch(
        {400, _, ~"{multipart,no_part_terminator}"},
        request(Config, multipart_head(~"/read_parts", byte_size(Body)), Body)
    ).

multipart_read_timeout(Config) ->
    Body = <<"--B\r\nx-name: a\r\n\r\nshort">>,
    ?assertMatch(
        {400, _, ~"timeout"},
        request(Config, multipart_head(~"/read_parts", 500), Body)
    ).

nova_multipart_plugin_uploads(Config) ->
    Body = <<
        "--B\r\ncontent-disposition: form-data; name=\"title\"\r\n\r\nhi\r\n",
        "--B\r\ncontent-disposition: form-data; name=\"doc\"; filename=\"a.txt\"\r\n",
        "content-type: text/plain\r\n\r\nfile body\r\n--B--\r\n"
    >>,
    {201, _, Json} = request(Config, multipart_head(~"/upload", byte_size(Body)), Body),
    ?assertEqual(#{~"params" => #{~"title" => ~"hi"}, ~"files" => 1}, json:decode(Json)).

nova_request_plugin_decodes_json(Config) ->
    Body = ~"{\"a\":1}",
    %% Nova answers a POST's `{json, _}` with 201.
    {201, _, Json} = request(
        Config,
        [
            ~"POST /json HTTP/1.1\r\ncontent-type: application/json\r\ncontent-length: ",
            integer_to_binary(byte_size(Body)),
            ~"\r\n"
        ],
        Body
    ),
    ?assertEqual(#{~"a" => 1}, json:decode(Json)).

%% =============================================================================
%% Listeners
%% =============================================================================

listener_without_compression(_Config) ->
    %% Nova names the listeners it starts at runtime with a tuple.
    Ref = {nova_listener, roadrunner_nova_test, plain},
    Port = free_port(),
    {ok, _} = roadrunner_nova:start_listener(
        Ref, #{ip => {0, 0, 0, 0}, port => Port, options => #{compress => false}}, env()
    ),
    {200, Headers, Body} = request(Port, ~"GET /big HTTP/1.1\r\naccept-encoding: gzip\r\n", <<>>),
    ?assertEqual(nomatch, re:run(Headers, "(?i)content-encoding")),
    ?assertEqual(4096, byte_size(Body)),
    ok = roadrunner_nova:stop_listener(Ref).

tls_listener(_Config) ->
    #{server_config := ServerConfig, client_config := ClientConfig} = certs(),
    Port = free_port(),
    {ok, _} = roadrunner_nova:start_listener(
        roadrunner_nova_tls,
        #{
            ip => {0, 0, 0, 0},
            port => Port,
            use_ssl => true,
            ssl_options => maps:from_list(ServerConfig)
        },
        env()
    ),
    {ok, {{_, 201, _}, _, Body}} = httpc:request(
        get,
        {"https://localhost:" ++ integer_to_list(Port) ++ "/binary_status", []},
        [{ssl, [{verify, verify_none} | proplists:delete(verify, ClientConfig)]}],
        [{body_format, binary}]
    ),
    ?assertEqual(~"made", Body),
    ok = roadrunner_nova:stop_listener(roadrunner_nova_tls).

deprecated_tls_options(Config) ->
    %% Nova's older `ca_cert` and `cert` keys name the certificate files.
    Dir = ?config(priv_dir, Config),
    #{server_config := ServerConfig} = certs(),
    Cert = filename:join(Dir, "cert.pem"),
    CACert = filename:join(Dir, "cacert.pem"),
    ok = file:write_file(Cert, pem('Certificate', proplists:get_value(cert, ServerConfig))),
    ok = file:write_file(
        CACert, pem('Certificate', hd(proplists:get_value(cacerts, ServerConfig)))
    ),
    Result = roadrunner_nova:start_listener(
        roadrunner_nova_old_tls,
        #{
            ip => {0, 0, 0, 0},
            port => free_port(),
            use_ssl => true,
            ca_cert => CACert,
            cert => Cert
        },
        env()
    ),
    %% The keys name no key file, so whether the listener starts depends on
    %% the OTP release: OTP 29 refuses it at once, older ones at the first
    %% handshake. Either way the files reached the TLS options.
    case Result of
        {ok, _} -> ok = roadrunner_nova:stop_listener(roadrunner_nova_old_tls);
        {error, _} -> ok
    end.

drains_listeners(_Config) ->
    Ref = {nova_listener, roadrunner_nova_test, drained},
    {ok, _} = roadrunner_nova:start_listener(
        Ref, #{ip => {0, 0, 0, 0}, port => free_port()}, env()
    ),
    %% A listener already gone is skipped.
    ok = roadrunner_nova:drain_listeners([Ref, roadrunner_nova_gone], 1000),
    ?assertEqual({error, not_found}, roadrunner_nova:stop_listener(roadrunner_nova_gone)).

%% =============================================================================
%% Helpers
%% =============================================================================

%% The environment a listener on Nova's default routing table runs with.
env() ->
    #{nova_dispatch_key => nova_dispatch, nova_middlewares => nova_server:middlewares(#{})}.

%% A server and client chain, with RSA keys as Roadrunner's own TLS tests
%% use.
certs() ->
    Key = fun() -> public_key:generate_key({rsa, 2048, 65537}) end,
    Chain = fun() ->
        #{root => [{key, Key()}, {digest, sha256}], peer => [{key, Key()}, {digest, sha256}]}
    end,
    public_key:pkix_test_data(#{server_chain => Chain(), client_chain => Chain()}).

pem(Type, Der) ->
    public_key:pem_encode([{Type, Der, not_encrypted}]).

multipart_head(Path, Size) ->
    [
        ~"POST ",
        Path,
        ~" HTTP/1.1\r\ncontent-type: multipart/form-data; boundary=B\r\ncontent-length: ",
        integer_to_binary(Size),
        ~"\r\n"
    ].

headers() ->
    ~"host: localhost\r\nconnection: close\r\n".

%% A request on its own connection: the request line and any headers in
%% `Head`, then `Body`. Returns the status, the raw header block, and the
%% body, de-chunked.
request(Config, Head, Body) when is_list(Config) ->
    request(?config(port, Config), Head, Body);
request(Port, Head, Body) ->
    Raw = raw(Port, [Head, headers(), ~"\r\n", Body]),
    <<"HTTP/1.1 ", Code:3/binary, _/binary>> = Raw,
    [Headers, RespBody] = binary:split(Raw, ~"\r\n\r\n"),
    {binary_to_integer(Code), <<Headers/binary, "\r\n">>, body(Headers, RespBody)}.

body(Headers, Body) ->
    case re:run(Headers, "(?i)\r\ntransfer-encoding: chunked") of
        {match, _} -> dechunk(Body);
        nomatch -> Body
    end.

%% A chunked body's data, with its trailers kept after it.
dechunk(Body) ->
    [SizeLine, Rest] = binary:split(Body, ~"\r\n"),
    case binary_to_integer(SizeLine, 16) of
        0 ->
            Rest;
        Size ->
            <<Data:Size/binary, "\r\n", More/binary>> = Rest,
            <<Data/binary, (dechunk(More))/binary>>
    end.

raw(Config, Data) when is_list(Config), is_tuple(hd(Config)) ->
    raw(?config(port, Config), Data);
raw(Port, Data) ->
    {ok, Socket} = gen_tcp:connect("localhost", Port, [binary, {active, false}]),
    ok = gen_tcp:send(Socket, Data),
    Response = recv_all(Socket, <<>>),
    ok = gen_tcp:close(Socket),
    Response.

recv_all(Socket, Acc) ->
    case gen_tcp:recv(Socket, 0, 10000) of
        {ok, Bytes} -> recv_all(Socket, <<Acc/binary, Bytes/binary>>);
        {error, closed} -> Acc
    end.

free_port() ->
    {ok, Socket} = gen_tcp:listen(0, [{reuseaddr, true}]),
    {ok, Port} = inet:port(Socket),
    ok = gen_tcp:close(Socket),
    Port.
