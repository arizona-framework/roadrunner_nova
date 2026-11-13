-module(roadrunner_nova_handler).
-moduledoc false.

%% The Roadrunner handler behind every Nova listener. It answers each
%% request with a `{send, [], Fun}` response, and the fun runs Nova's
%% pipeline on a Cowboy-shaped request map (`nova_server`), so Nova's code
%% sends its response through `roadrunner_nova` as it decides to.

-behaviour(roadrunner_handler).

-export([handle/1]).
-export([run/1, request/2]).

-spec handle(roadrunner_req:request()) -> roadrunner_handler:result().
handle(Req) ->
    {{send, [], fun ?MODULE:run/1}, Req}.

%% Run Nova's pipeline. One that ends with nothing sent is answered `204`,
%% as Cowboy does.
-spec run(roadrunner_req:request()) -> roadrunner_req:request().
run(RR0) ->
    #{env := Env, compress := Compress} = roadrunner_req:state(RR0),
    Req0 = nova_session:start_request(request(RR0, Compress)),
    #{roadrunner_req := RR} =
        case nova_server:execute(Req0, Env) of
            {ok, Req, _Env} -> Req;
            {stop, Req} -> Req
        end,
    case roadrunner_send:status(RR) of
        none -> ok = roadrunner_send:reply(204, [], <<>>, RR);
        _Sent -> ok
    end,
    RR.

%% The request map Nova's code reads, with the keys and value types of
%% Cowboy's (see `nova_server`).
-spec request(roadrunner_req:request(), boolean()) -> cowboy_req:req().
request(RR, Compress) ->
    Headers = headers(roadrunner_req:headers(RR)),
    Scheme = roadrunner_req:scheme(RR),
    HasBody = roadrunner_req:has_body(RR),
    #{
        nova_server => roadrunner_nova,
        roadrunner_req => RR,
        roadrunner_compress => Compress,
        ref => roadrunner_req:listener_name(RR),
        pid => self(),
        streamid => roadrunner_req:request_id(RR),
        method => roadrunner_req:method(RR),
        version => version(roadrunner_req:version(RR)),
        scheme => atom_to_binary(Scheme),
        host => host(roadrunner_req:host(RR)),
        port => roadrunner_req:port(RR),
        path => roadrunner_req:path(RR),
        qs => roadrunner_req:qs(RR),
        headers => Headers,
        peer => address(roadrunner_req:peer(RR)),
        sock => sock(RR),
        cert => cert(Scheme, RR),
        has_body => HasBody,
        body_length => body_length(Headers, HasBody)
    }.

%% Headers as a map, as Cowboy keeps them: a repeated header's values are
%% joined with `, `, and `cookie`'s with `; ` (RFC 9113 §8.2.3).
-spec headers(roadrunner_http:headers()) -> cowboy:http_headers().
headers(Headers) ->
    lists:foldl(
        fun({Name, Value}, Acc) ->
            case Acc of
                #{Name := Prev} ->
                    Acc#{Name := <<Prev/binary, (separator(Name))/binary, Value/binary>>};
                #{} ->
                    Acc#{Name => Value}
            end
        end,
        #{},
        Headers
    ).

-spec separator(binary()) -> binary().
separator(~"cookie") -> ~"; ";
separator(_Name) -> ~", ".

-spec version(roadrunner_http:version()) -> cowboy:http_version().
version({1, 0}) -> 'HTTP/1.0';
version({1, 1}) -> 'HTTP/1.1';
version({2, 0}) -> 'HTTP/2';
version({3, 0}) -> 'HTTP/3'.

%% Only an HTTP/1.0 request may name no host; Cowboy has `<<>>` for it.
-spec host(binary() | undefined) -> binary().
host(undefined) -> <<>>;
host(Host) -> Host.

-spec sock(roadrunner_req:request()) -> {inet:ip_address(), inet:port_number()}.
sock(RR) ->
    case roadrunner_req:sockname(RR) of
        {ok, Sock} -> Sock;
        {error, _} -> address(undefined)
    end.

%% An address the OS could not report (the socket already closing) as the
%% unspecified one, since Cowboy's request always has one.
-spec address({inet:ip_address(), inet:port_number()} | undefined) ->
    {inet:ip_address(), inet:port_number()}.
address(undefined) -> {{0, 0, 0, 0}, 0};
address(Address) -> Address.

-spec cert(http | https, roadrunner_req:request()) -> binary() | undefined.
cert(https, RR) ->
    case roadrunner_req:peercert(RR) of
        {ok, Der} -> Der;
        {error, _} -> undefined
    end;
cert(http, _RR) ->
    undefined.

%% The body's length when the request declares it, as Cowboy's
%% `body_length`: `undefined` for a body of unknown length (chunked, or an
%% HTTP/2 or HTTP/3 body without `content-length`).
-spec body_length(cowboy:http_headers(), boolean()) -> non_neg_integer() | undefined.
body_length(#{~"content-length" := Length}, _HasBody) -> binary_to_integer(Length);
body_length(_Headers, false) -> 0;
body_length(_Headers, true) -> undefined.
