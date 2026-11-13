-module(roadrunner_nova).
-moduledoc """
Run [Nova](https://github.com/novaframework/nova) on Roadrunner.

This module is a Nova server (`nova_server`). Set it as Nova's `server`,
and Nova's listeners run on Roadrunner instead of Cowboy:

```erlang
{nova, [
    {server, roadrunner_nova},
    {cowboy_configuration, #{port => 8080}}
]}
```

The configuration keeps the shape of Nova's `cowboy_configuration` key:

- `ip`, `port`, and for TLS `use_ssl => true`, `ssl_port` and
  `ssl_options` (the `ssl` server options)
- `options`: `compress` (on by default, as with Cowboy) compresses
  responses with `roadrunner_compress`
- `roadrunner`: any other `t:roadrunner_listener:opts/0`, such as
  `max_clients` or `request_timeout`

Cowboy-only keys (`stream_handlers`, and the rest of `options`) are
ignored.

Controllers, plugins and WebSocket handlers run unchanged, as long as they
use `nova_req` rather than `cowboy_req` for anything that touches the
connection (sending a response, reading the body).
""".

-behaviour(nova_server).

-export([
    start_listener/3,
    stop_listener/1,
    drain_listeners/2,
    reply/4,
    inform/3,
    stream_reply/3,
    stream_body/3,
    stream_trailers/2,
    read_body/2,
    read_part/2,
    read_part_body/2,
    upgrade/5,
    upgrade/6
]).

%% Exported for its unit test: Nova's WebSocket handler passes no options
%% today, so no request reaches `upgrade/6`'s mapping of them.
-export([ws_opts/2]).

%% Cowboy's defaults for the body-reading options.
-define(READ_BODY_LENGTH, 8000000).
-define(READ_PART_LENGTH, 64000).

%% =============================================================================
%% Listeners
%% =============================================================================

-doc false.
-spec start_listener(nova_server:listener_ref(), map(), map()) -> {ok, pid()} | {error, term()}.
start_listener(Ref, #{ip := Ip, port := Port} = Configuration, Env) ->
    Options = maps:get(options, Configuration, #{compress => true}),
    State = #{env => Env, compress => maps:get(compress, Options, false) =:= true},
    Opts = maps:merge(
        maps:get(roadrunner, Configuration, #{}),
        (tls(Configuration))#{
            ip => Ip,
            port => Port,
            body_buffering => manual,
            routes => {roadrunner_nova_handler, State}
        }
    ),
    %% Nova starts its listeners as its own supervisor starts, which can be
    %% before Roadrunner's application is.
    {ok, _} = application:ensure_all_started(roadrunner),
    roadrunner:start_listener(name(Ref), Opts).

-doc false.
-spec stop_listener(nova_server:listener_ref()) -> ok | {error, not_found}.
stop_listener(Ref) ->
    roadrunner:stop_listener(name(Ref)).

-doc false.
-spec drain_listeners([nova_server:listener_ref()], non_neg_integer()) -> ok.
drain_listeners(Refs, Timeout) ->
    %% Each drain waits for its own connections, so they run side by side.
    Self = self(),
    Pids = [
        spawn_link(fun() -> Self ! {drained, self(), drain(name(Ref), Timeout)} end)
     || Ref <- Refs
    ],
    lists:foreach(
        fun(Pid) ->
            receive
                {drained, Pid, _Result} -> ok
            end
        end,
        Pids
    ).

-spec drain(atom(), non_neg_integer()) -> term().
drain(Name, Timeout) ->
    try
        roadrunner_listener:drain(Name, Timeout)
    catch
        %% Already gone: an application removed at runtime.
        exit:{noproc, _} -> ok
    end.

%% The listener's TLS options, as Nova's configuration names them. Nova
%% resolves the port to bind, `ssl_port` for TLS, before calling
%% `start_listener/3`.
-spec tls(map()) -> map().
tls(#{use_ssl := true} = Configuration) ->
    #{tls => tls_options(Configuration)};
tls(_Configuration) ->
    #{}.

-spec tls_options(map()) -> [ssl:tls_server_option()].
tls_options(#{ca_cert := CACert, cert := Cert}) ->
    [{certfile, Cert}, {cacertfile, CACert}];
tls_options(Configuration) ->
    maps:to_list(maps:get(ssl_options, Configuration, #{})).

%% Roadrunner names listeners with atoms; Nova's refs are atoms or tuples
%% (`{nova_listener, App, Port}`), one per listener Nova starts.
-spec name(nova_server:listener_ref()) -> atom().
name(Ref) when is_atom(Ref) ->
    Ref;
name(Ref) ->
    binary_to_atom(iolist_to_binary(io_lib:format("~0p", [Ref]))).

%% =============================================================================
%% Requests
%% =============================================================================

-doc false.
-spec reply(cowboy:http_status(), cowboy:http_headers(), cowboy_req:resp_body(), Req) -> Req when
    Req :: cowboy_req:req().
reply(Status, Headers0, {sendfile, Offset, Length, Path}, Req) ->
    Headers = with_content_length(Length, response_headers(Headers0, Req)),
    _ = roadrunner_send:file(Status, Headers, {Path, Offset, Length}, rr(Req)),
    replied(Req);
reply(Status, Headers0, Body0, #{roadrunner_compress := Compress} = Req) ->
    RR = rr(Req),
    {Headers, Body} =
        case Compress of
            true -> roadrunner_compress:buffered(RR, response_headers(Headers0, Req), Body0);
            false -> {response_headers(Headers0, Req), Body0}
        end,
    _ = roadrunner_send:reply(status(Status), Headers, Body, RR),
    replied(Req).

-doc false.
-spec inform(cowboy:http_status(), cowboy:http_headers(), cowboy_req:req()) -> ok.
inform(Status, Headers, Req) ->
    _ = roadrunner_send:inform(status(Status), header_list(Headers), rr(Req)),
    ok.

-doc false.
-spec stream_reply(cowboy:http_status(), cowboy:http_headers(), Req) -> Req when
    Req :: cowboy_req:req().
stream_reply(Status, Headers, Req) ->
    {ok, Send} = roadrunner_send:stream(
        status(Status), response_headers(Headers, Req), rr(Req)
    ),
    (replied(Req))#{roadrunner_stream => Send}.

-doc false.
-spec stream_body(iodata(), fin | nofin, cowboy_req:req()) -> ok.
stream_body(Data, IsFin, #{roadrunner_stream := Send}) ->
    _ = Send(Data, IsFin),
    ok.

-doc false.
-spec stream_trailers(cowboy:http_headers(), cowboy_req:req()) -> ok.
stream_trailers(Trailers, #{roadrunner_stream := Send}) ->
    _ = Send(<<>>, {fin, header_list(Trailers)}),
    ok.

-doc false.
-spec read_body(Req, cowboy_req:read_body_opts()) ->
    {ok, binary(), Req} | {more, binary(), Req}
when
    Req :: cowboy_req:req().
read_body(Req, Opts) ->
    Length = maps:get(length, Opts, ?READ_BODY_LENGTH),
    case roadrunner_req:read_body(rr(Req), #{length => Length}) of
        {ok, Data, RR} -> {ok, iolist_to_binary(Data), Req#{roadrunner_req := RR}};
        {more, Data, RR} -> {more, iolist_to_binary(Data), Req#{roadrunner_req := RR}};
        {error, Reason} -> exit(request_error(Reason))
    end.

-doc false.
-spec read_part(Req, cowboy_req:read_body_opts()) ->
    {ok, cowboy:http_headers(), Req} | {done, Req}
when
    Req :: cowboy_req:req().
read_part(Req, Opts) ->
    Length = maps:get(length, Opts, ?READ_PART_LENGTH),
    case roadrunner_multipart:read_part(rr(Req), #{length => Length}) of
        {ok, Headers, RR} -> {ok, maps:from_list(Headers), Req#{roadrunner_req := RR}};
        {done, RR} -> {done, Req#{roadrunner_req := RR}};
        {error, Reason} -> exit(multipart_error(Reason))
    end.

-doc false.
-spec read_part_body(Req, cowboy_req:read_body_opts()) ->
    {ok, binary(), Req} | {more, binary(), Req}
when
    Req :: cowboy_req:req().
read_part_body(Req, Opts) ->
    Length = maps:get(length, Opts, ?READ_BODY_LENGTH),
    case roadrunner_multipart:read_part_body(rr(Req), #{length => Length}) of
        {ok, Data, RR} -> {ok, Data, Req#{roadrunner_req := RR}};
        {more, Data, RR} -> {more, Data, Req#{roadrunner_req := RR}};
        {error, Reason} -> exit(multipart_error(Reason))
    end.

-doc false.
-spec upgrade(module(), Req, Env, module(), term()) -> {ok, Req, Env} when
    Req :: cowboy_req:req(), Env :: map().
upgrade(Mod, Req, Env, Handler, State) ->
    upgrade(Mod, Req, Env, Handler, State, #{}).

-doc false.
-spec upgrade(module(), Req, Env, module(), term(), cowboy_websocket:opts()) ->
    {ok, Req, Env}
when
    Req :: cowboy_req:req(), Env :: map().
upgrade(cowboy_websocket, Req, Env, Handler, State, Opts) ->
    Session = #{handler => Handler, state => State, req => Req},
    _ = roadrunner_send:websocket(roadrunner_nova_ws, Session, ws_opts(Opts, Req), rr(Req)),
    {ok, replied(Req), Env}.

%% Cowboy's WebSocket options that have a Roadrunner counterpart.
-doc false.
-spec ws_opts(cowboy_websocket:opts(), cowboy_req:req()) -> roadrunner_ws_handler:upgrade_opts().
ws_opts(Opts, Req) ->
    maps:fold(
        fun
            (idle_timeout, Timeout, Acc) -> Acc#{idle_timeout => Timeout};
            (max_frame_size, infinity, Acc) -> Acc;
            (max_frame_size, Size, Acc) -> Acc#{max_frame_size => Size, max_message_size => Size};
            (compress, Compress, Acc) -> Acc#{compress => Compress};
            (_Key, _Value, Acc) -> Acc
        end,
        #{headers => cookie_headers(Req)},
        Opts
    ).

%% =============================================================================
%% Helpers
%% =============================================================================

-spec rr(cowboy_req:req()) -> roadrunner_req:request().
rr(#{roadrunner_req := RR}) -> RR.

%% A request after its response went out, as `cowboy_req` leaves it.
-spec replied(Req) -> Req when Req :: cowboy_req:req().
replied(Req) ->
    (maps:without([resp_headers, resp_cookies, resp_body], Req))#{has_sent_resp => true}.

%% The headers a response carries: those set on the request, the call's
%% (which win), and a `set-cookie` for each cookie set on the request.
-spec response_headers(cowboy:http_headers(), cowboy_req:req()) -> roadrunner_http:headers().
response_headers(Headers, Req) ->
    maps:fold(
        fun(Name, Value, Acc) -> [{Name, iolist_to_binary(Value)} | Acc] end,
        cookie_headers(Req),
        maps:merge(maps:get(resp_headers, Req, #{}), Headers)
    ).

-spec cookie_headers(cowboy_req:req()) -> roadrunner_http:headers().
cookie_headers(#{resp_cookies := Cookies}) ->
    [{~"set-cookie", iolist_to_binary(Value)} || _Name := Value <- Cookies];
cookie_headers(_Req) ->
    [].

-spec header_list(cowboy:http_headers()) -> roadrunner_http:headers().
header_list(Headers) ->
    [{Name, iolist_to_binary(Value)} || Name := Value <- Headers].

-spec with_content_length(non_neg_integer(), roadrunner_http:headers()) ->
    roadrunner_http:headers().
with_content_length(Length, Headers) ->
    case lists:keymember(~"content-length", 1, Headers) of
        true -> Headers;
        false -> [{~"content-length", integer_to_binary(Length)} | Headers]
    end.

%% Cowboy takes a status as an integer or a binary such as `<<"200 OK">>`.
-spec status(cowboy:http_status()) -> roadrunner_http:status().
status(Status) when is_integer(Status) -> Status;
status(<<Code:3/binary, _/binary>>) -> binary_to_integer(Code).

%% A body read that failed, as the exit Cowboy raises for it, which Nova's
%% plugins turn into a response (`408`, `413`, `400`).
-spec request_error(term()) -> {request_error, term(), atom()}.
request_error(Reason) when
    Reason =:= request_timeout; Reason =:= slow_client; Reason =:= timeout
->
    {request_error, timeout, 'The request body was not received within the configured time.'};
request_error(content_length_too_large) ->
    {request_error, payload_too_large, 'The request body is larger than allowed by configuration.'};
request_error(Reason) ->
    {request_error, Reason, 'The request body could not be read.'}.

%% A multipart body that is not well formed, as Cowboy's `{multipart, _}`
%% request error, or a failed read of it.
-spec multipart_error(term()) -> {request_error, term(), atom()}.
multipart_error(Reason) when
    Reason =:= not_multipart;
    Reason =:= no_boundary;
    Reason =:= no_initial_boundary;
    Reason =:= no_header_terminator;
    Reason =:= no_part_terminator;
    Reason =:= headers_too_large;
    Reason =:= bad_header;
    Reason =:= malformed
->
    {request_error, {multipart, Reason}, 'Malformed body; multipart expected.'};
multipart_error(Reason) ->
    request_error(Reason).
