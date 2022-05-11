-module(prop_cowmachine_simple).
-include_lib("proper/include/proper.hrl").

-export([
    execute/2,
    process/4
]).

%%%%%%%%%%%%%%%%%%
%%% Properties %%%
%%%%%%%%%%%%%%%%%%

%% shell command for a test: rebar3 proper -p prop_cowmachine_start
prop_cowmachine_start() ->
 
		?FORALL(_Type, boolean(),
			begin
				{ok, _} = application:ensure_all_started(cowmachine),
				TestPid = self(), 
				spawn_link(fun() ->
                  {ok, _} = cowboy:start_clear(
                              cowmachine_test_listener,
                              [ inet, {port, 1234} ],
                              cowboy_options()),
                  TestPid ! started
				end),
				
				%% Wait for the server to start
				receive started -> ok end,
				
				%% Do a request to the test server, and check the response
				{ok, {{"HTTP/1.1", 200, "OK"}, _Headers, "Hello World"}} = httpc:request("http://127.0.0.1:1234/"),
				%Result = httpc:request("http://127.0.0.1:1234/"),
				%io:format("~p~n",[Result]),
				
				ok = cowboy:stop_listener(cowmachine_test_listener),
				true
			end)
	.
%%%%%%%%%%%%%%%
%%% Helpers %%%
%%%%%%%%%%%%%%%

%% Use this module as middleware, and controller
cowboy_options() ->
    #{ middlewares => [ ?MODULE, cowmachine ] }.

%% Middleware export,  places this module in the request as controller.
execute(Req, Env) ->
    {ok, Req, Env#{ cowmachine_controller => ?MODULE } }.

%% Controller export
process(<<"GET">>, _ContentType, _Accepted, Context) ->
    {<<"Hello World">>, Context}.
