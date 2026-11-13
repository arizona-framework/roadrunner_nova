-module(roadrunner_nova_test_plugin).
-moduledoc false.

%% A Nova plugin for `roadrunner_nova_SUITE`: its `action` option picks what
%% it does with the request through `nova_req`, then it stops the pipeline.

-behaviour(nova_plugin).

-export([pre_request/4, post_request/4, plugin_info/0]).

pre_request(Req0, _Env, #{action := Action} = Options, State) ->
    {stop, act(Action, Req0, Options), State}.

post_request(Req, _Env, _Options, State) ->
    {ok, Req, State}.

plugin_info() ->
    #{
        title => ~"roadrunner_nova test plugin",
        version => ~"0.0.0",
        url => ~"https://github.com/arizona-framework/roadrunner_nova",
        authors => [~"roadrunner_nova"],
        description => ~"Drives nova_req from a plugin."
    }.

act(nothing, Req, _Options) ->
    Req;
act(inform, Req, _Options) ->
    ok = nova_req:inform(103, #{~"link" => ~"</a.css>; rel=preload"}, Req),
    nova_req:reply(200, #{}, ~"after hints", Req);
act(stream, Req0, _Options) ->
    Req = nova_req:stream_reply(200, #{~"content-type" => ~"text/plain"}, Req0),
    ok = nova_req:stream_body(~"body-", nofin, Req),
    ok = nova_req:stream_events(#{data => ~"one"}, nofin, Req),
    ok = nova_req:stream_events([#{data => ~"two"}], nofin, Req),
    ok = nova_req:stream_trailers(#{~"x-sum" => ~"1"}, Req),
    Req;
act(binary_status, Req, _Options) ->
    nova_req:reply(~"201 Created", #{}, ~"made", Req);
act(sendfile, Req, #{file := File}) ->
    nova_req:reply(200, #{~"content-type" => ~"text/plain"}, {sendfile, 1, 3, File}, Req);
act(sendfile_sized, Req, #{file := File}) ->
    Headers = #{~"content-type" => ~"text/plain", ~"content-length" => ~"3"},
    nova_req:reply(200, Headers, {sendfile, 1, 3, File}, Req);
act(cookie, Req0, _Options) ->
    Req1 = nova_req:set_resp_cookie(~"a", ~"1", Req0),
    Req2 = nova_req:set_resp_header(~"x-set", ~"v", Req1),
    Req = nova_req:set_resp_body(~"with cookie", Req2),
    nova_req:reply(200, Req);
act(big, Req, _Options) ->
    nova_req:reply(200, #{~"content-type" => ~"text/plain"}, binary:copy(~"a", 4096), Req);
act(read_body, Req, _Options) ->
    guarded(fun() -> read_body(Req, []) end, Req);
act(read_parts, Req, _Options) ->
    guarded(fun() -> read_parts(Req, []) end, Req).

read_body(Req0, Acc) ->
    case nova_req:read_body(Req0, #{length => 4}) of
        {more, Data, Req} -> read_body(Req, [Data | Acc]);
        {ok, Data, Req} -> {lists:reverse(Acc, [Data]), Req}
    end.

read_parts(Req0, Acc) ->
    case nova_req:read_part(Req0) of
        {ok, #{~"x-name" := Name}, Req1} ->
            {Body, Req} = read_part_body(Req1, []),
            read_parts(Req, [[Name, $=, Body, $;] | Acc]);
        {done, Req} ->
            {lists:reverse(Acc), Req}
    end.

read_part_body(Req0, Acc) ->
    case nova_req:read_part_body(Req0, #{length => 3}) of
        {more, Data, Req} -> read_part_body(Req, [Data | Acc]);
        {ok, Data, Req} -> {lists:reverse(Acc, [Data]), Req}
    end.

%% What the read gave, or the request error it exited with, as Cowboy's
%% read functions exit.
guarded(Read, Req0) ->
    try Read() of
        {Body, Req} -> nova_req:reply(200, #{}, Body, Req)
    catch
        exit:{request_error, Reason, _Message} ->
            nova_req:reply(400, #{}, iolist_to_binary(io_lib:format("~0p", [Reason])), Req0)
    end.
