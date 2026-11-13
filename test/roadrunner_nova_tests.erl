-module(roadrunner_nova_tests).

-include_lib("eunit/include/eunit.hrl").

ws_opts_without_options_test() ->
    ?assertEqual(#{headers => []}, roadrunner_nova:ws_opts(#{}, #{})).

ws_opts_maps_cowboy_options_test() ->
    Opts = #{idle_timeout => 1000, max_frame_size => 64, compress => true, active_n => 10},
    ?assertEqual(
        #{
            headers => [{~"set-cookie", ~"session_id=1"}],
            idle_timeout => 1000,
            max_frame_size => 64,
            max_message_size => 64,
            compress => true
        },
        roadrunner_nova:ws_opts(Opts, #{resp_cookies => #{~"session_id" => ~"session_id=1"}})
    ).

ws_opts_unbounded_frames_test() ->
    ?assertEqual(
        #{headers => []}, roadrunner_nova:ws_opts(#{max_frame_size => infinity}, #{})
    ).
