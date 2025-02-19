%% @author Marc Worrell <marc@worrell.nl>
%% @copyright 2016-2019 Marc Worrell
%%
%% @doc Middleware to update proxy settings in the Cowboy Req.
%% @reference See more information related to Cowboy Req at 
%% <a href="https://ninenines.eu/docs/en/cowboy/2.9/manual/cowboy_req/">cowboy_req(3)</a>.
%% @end

%% Copyright 2016-2019 Marc Worrell
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%% 
%%     http://www.apache.org/licenses/LICENSE-2.0
%% 
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.

-module(cowmachine_proxy).
-author("Marc Worrell <marc@worrell.nl").

-behaviour(cowboy_middleware).

-export([
    execute/2,
    update_env/2
]).

-include_lib("cowlib/include/cow_parse.hrl").
-include("cowmachine_log.hrl").

%% @doc Cowboy middleware, route the new request. Continue with the cowmachine,
%%      requests a redirect or return a `400' on an unknown host.

-spec execute(Req, Env) -> Result when
	Req :: cowboy_req:req(), 
	Env :: cowboy_middleware:env(),
	Result :: {ok, Req, Env} | {stop, Req}.
execute(Req, Env) ->
    {ok, Req, update_env(Req, Env)}.

%% @doc Update the environment based on the content of the request.

-spec update_env(Req, Env) -> Result when
	Req :: cowboy_req:req(), 
	Env :: cowboy_middleware:env(),
	Result :: cowboy_middleware:env().
update_env(Req, Env) ->
    case cowboy_req:header(<<"forwarded">>, Req) of
        undefined ->
            case cowboy_req:header(<<"x-forwarded-for">>, Req) of
                undefined ->
                    update_env_direct(Req, Env);
                XForwardedFor ->
                    update_env_old_proxy(XForwardedFor, Req, Env)
            end;
        Forwarded ->
            update_env_proxy(Forwarded, Req, Env)
    end.

%% @doc Fetch the metadata from the request itself.

-spec update_env_direct(Req, Env) -> Result when
	Req :: cowboy_req:req(), 
	Env :: cowboy_middleware:env(),
	Result :: cowboy_middleware:env().	
update_env_direct(Req, Env) ->
    {Peer, _Port} = cowboy_req:peer(Req),
    Env#{
        cowmachine_proxy => false,
        cowmachine_forwarded_host => parse_host(maps:get(host, Req)),
        cowmachine_forwarded_port => cowboy_req:port(Req),
        cowmachine_forwarded_proto => cowboy_req:scheme(Req),
        cowmachine_remote_ip => Peer,
        cowmachine_remote => list_to_binary(inet_parse:ntoa(Peer))
    }.

%% @doc Handle the `Forwarded' header, added by the proxy.

-spec update_env_proxy(Forwarded, Req, Env) -> Result when
	Forwarded :: binary(), 
	Req :: cowboy_req:req(), 
	Env :: cowboy_middleware:env(),
	Result :: cowboy_middleware:env().	
update_env_proxy(Forwarded, Req, Env) ->
    {Peer, _Port} = cowboy_req:peer(Req),
    case is_trusted_proxy(Peer) of
        true ->
            Props = parse_forwarded(Forwarded),
            {Remote, RemoteAdr} = case proplists:get_value(<<"for">>, Props) of
                        undefined ->
                            {list_to_binary(inet_parse:ntoa(Peer)), Peer};
                        For ->
                            parse_for(For, Req)
                     end,
            Proto = proplists:get_value(<<"proto">>, Props, <<"http">>),
            Host = case proplists:get_value(<<"host">>, Props) of
                        undefined -> cowboy_req:header(<<"host">>, Req);
                        XHost -> XHost
                   end,
            Port = case proplists:get_value(<<"port">>, Props) of
                        undefined ->
                            case Proto of
                                <<"https">> -> 443;
                                _ -> 80
                            end;
                        XPort -> z_convert:to_integer(XPort)
                   end,
            Env#{
                cowmachine_proxy => true,
                cowmachine_forwarded_host => parse_host(Host),
                cowmachine_forwarded_port => Port,
                cowmachine_forwarded_proto => Proto,
                cowmachine_remote_ip => Remote,
                cowmachine_remote => RemoteAdr
            };
        false ->
            cowmachine:log(#{ level => debug,
                              at => ?AT,
                              text => "Received proxy header 'Forwarded' from untrusted peer"
                            }, Req),
            update_env_direct(Req, Env)
    end.

%% @doc Handle the `X-Forwarded-For' header, added by the proxy.

update_env_old_proxy(XForwardedFor, Req, Env) ->
    {Peer, _Port} = cowboy_req:peer(Req),
    case is_trusted_proxy(Peer) of
        true ->
            FwdFor = z_string:trim(lists:last(binary:split(XForwardedFor, <<",">>, [global]))),
            {Remote, RemoteAdr} = parse_for(FwdFor, Req),
            Proto = case trim(cowboy_req:header(<<"x-forwarded-proto">>, Req)) of
                        undefined -> <<"http">>;
                        XProto -> XProto
                    end,
            Host = case cowboy_req:header(<<"x-forwarded-host">>, Req) of
                        undefined -> cowboy_req:header(<<"host">>, Req);
                        XHost -> XHost
                   end,
            Port = case cowboy_req:header(<<"x-forwarded-port">>, Req) of
                        undefined ->
                            case Proto of
                                <<"https">> -> 443;
                                _ -> 80
                            end;
                        XPort -> z_convert:to_integer(XPort)
                   end,
            Env#{
                cowmachine_proxy => true,
                cowmachine_forwarded_host => parse_host(Host),
                cowmachine_forwarded_port => Port,
                cowmachine_forwarded_proto => Proto,
                cowmachine_remote_ip => Remote,
                cowmachine_remote => RemoteAdr
            };
        false ->
            cowmachine:log(#{ level => debug,
                              at => ?AT,
                              text => "Received proxy header 'X-Forwarded-For' from untrusted peer"
                            }, Req),

            update_env_direct(Req, Env)

    end.

-spec trim(String) -> Result when
	String :: undefined | iodata(),
	Result :: undefined | binary().
trim(undefined) -> undefined;
trim(S) -> z_string:trim(S).

-spec parse_host(Host) -> Result when
	Host :: undefined | binary(),
	Result :: undefined | binary().
parse_host(undefined) ->
    undefined;
parse_host(Host) ->
    {Host1, _} = cow_http_hd:parse_host(Host),
    sanitize_host(Host1).

-spec parse_for(For, Req) -> Result when
	For :: undefined | binary(),
	Req :: cowboy_req:req(),
	Result :: {Host, Adr},
	Host :: binary(),
	Adr :: inet:ip_address().
parse_for(undefined, Req) ->
    {Peer, _Port} = cowboy_req:peer(Req),
    {list_to_binary(inet_parse:ntoa(Peer)), Peer};
parse_for(<<$[, Rest/binary>>, _Req) ->
    IP6 = hd(binary:split(Rest, <<"]">>)),
    {ok, Adr} = inet_parse:address(binary_to_list(IP6)),
    {Adr, IP6};
parse_for(For, Req) ->
    case inet_parse:address(binary_to_list(For)) of
        {ok, Adr} ->
            {Adr, For};
        {error, _} -> 
            % Not an IP address, take the Proxy address
            {Peer, _Port} = cowboy_req:peer(Req),
            {Peer, sanitize(For)}
    end.

%% @equiv sanitize(For, <<>>)

-spec sanitize(For) -> Result when
	For :: binary(),
	Result :: binary().
sanitize(For) ->
    sanitize(For, <<>>).

-spec sanitize(For, Acc) -> Result when
	For :: binary(),
	Acc :: binary(),
	Result :: binary().
sanitize(<<>>, Acc) -> Acc;
sanitize(<<C, Rest/binary>>, Acc) when ?IS_URI_UNRESERVED(C) -> sanitize(Rest, <<Acc/binary, C>>);
sanitize(<<_, Rest/binary>>, Acc) -> sanitize(Rest, <<Acc/binary, $->>).

%% @equiv forwarded_list(Header, [])

-spec parse_forwarded(Header) -> Result when
	Header :: binary(),
	Result :: [{binary(), binary()}].
parse_forwarded(Header) when is_binary(Header) ->
    forwarded_list(Header, []).

-spec forwarded_list(Header, Acc) -> Result when
	Header :: binary(),
	Acc :: [{binary(),binary()}],
	Result :: [{binary(),binary()}].
forwarded_list(<<>>, Acc) -> lists:reverse(Acc);
forwarded_list(<<$,, R/bits>>, _Acc) -> forwarded_list(R, []);
forwarded_list(<< C, R/bits >>, Acc) when ?IS_WS(C) -> forwarded_list(R, Acc);
forwarded_list(<< $;, R/bits >>, Acc) -> forwarded_list(R, Acc);
forwarded_list(<< C, R/bits >>, Acc) when ?IS_ALPHANUM(C) -> forwarded_pair(R, Acc, << (lower(C)) >>).

-spec forwarded_pair(Header, Acc, T) -> Result when
	Header :: binary(), 
	Acc :: [{binary(),binary()}], 
	T :: binary(),
	Result :: [{binary(),binary()}].
forwarded_pair(<< C, R/bits >>, Acc, T) when ?IS_ALPHANUM(C) -> forwarded_pair(R, Acc, << T/binary, (lower(C)) >>);
forwarded_pair(R, Acc, T) -> forwarded_pair_eq(R, Acc, T).

-spec forwarded_pair_eq(Header, Acc, T) -> Result when
	Header :: binary(), 
	Acc :: [{binary(),binary()}], 
	T :: binary(),
	Result :: [{binary(),binary()}].
forwarded_pair_eq(<< C, R/bits >>, Acc, T) when ?IS_WS(C) -> forwarded_pair_eq(R, Acc, T);
forwarded_pair_eq(<< $=, R/bits >>, Acc, T) -> forwarded_pair_value(R, Acc, T).

-spec forwarded_pair_value(Header, Acc, T) -> Result when
	Header :: binary(), 
	Acc :: [{binary(),binary()}], 
	T :: binary(),
	Result :: [{binary(),binary()}].
forwarded_pair_value(<< C, R/bits>>, Acc, T) when ?IS_WS(C) -> forwarded_pair_value(R, Acc, T);
forwarded_pair_value(<< $", R/bits>>, Acc, T) -> forwarded_pair_value_quoted(R, Acc, T, <<>>);
forwarded_pair_value(<< C, R/bits>>, Acc, T) -> forwarded_pair_value_token(R, Acc, T, << (lower(C)) >>).

-spec forwarded_pair_value_token(Header, Acc, T, V) -> Result when
	Header :: binary(), 
	Acc :: [{binary(),binary()}], 
	T :: binary(),
	V :: binary(),
	Result :: [{binary(),binary()}].
forwarded_pair_value_token(<< C, R/bits>>, Acc, T, V) when ?IS_TOKEN(C) -> forwarded_pair_value_token(R, Acc, T, << V/binary, (lower(C)) >>);
forwarded_pair_value_token(R, Acc, T, V) -> forwarded_list(R, [{T, V}|Acc]).

-spec forwarded_pair_value_quoted(Header, Acc, T, V) -> Result when
	Header :: binary(), 
	Acc :: [{binary(),binary()}], 
	T :: binary(),
	V :: binary(),
	Result :: [{binary(),binary()}].
forwarded_pair_value_quoted(<< $", R/bits >>, Acc, T, V) -> forwarded_list(R, [{T, V}|Acc]);
forwarded_pair_value_quoted(<< $\\, C, R/bits >>, Acc, T, V) -> forwarded_pair_value_quoted(R, Acc, T, << V/binary, (lower(C)) >>);
forwarded_pair_value_quoted(<< C, R/bits >>, Acc, T, V) -> forwarded_pair_value_quoted(R, Acc, T, << V/binary, (lower(C)) >>).

-spec lower(Character) -> Result when
	Character :: char(),
	Result :: char().
lower(C) when C >= $A, C =< $Z -> C + 32;
lower(C) -> C.

%% @doc Check if the given proxy is trusted.

-spec is_trusted_proxy(Peer) -> Result when
	Peer :: inet:ip_address(),
	Result :: boolean().
is_trusted_proxy(Peer) ->
    case application:get_env(cowmachine, proxy_allowlist) of
        {ok, ProxyAllowlist} ->
            is_trusted_proxy(ProxyAllowlist, Peer);
        undefined ->
            is_trusted_proxy(local, Peer)
    end.

-spec is_trusted_proxy(Marker, Peer) -> Result when
	Marker :: ProxyMarker | ProxyAllowlist,
	ProxyMarker :: any | ip_whitelist | local | none,
	ProxyAllowlist :: list() | binary(),
	Peer :: inet:ip_address(),
	Result :: boolean().
is_trusted_proxy(none, _Peer) ->
    false;
is_trusted_proxy(any, _Peer) ->
    true;
is_trusted_proxy(local, Peer) ->
    z_ip_address:is_local(Peer);
is_trusted_proxy(ip_whitelist, Peer) ->
    case application:get_env(cowmachine, ip_allowlist) of
        {ok, Allowlist} ->
            z_ip_address:ip_match(Peer, Allowlist);
        undefined ->
            z_ip_address:is_local(Peer)
    end;
is_trusted_proxy(Allowlist, Peer) when is_list(Allowlist); is_binary(Allowlist) ->
    z_ip_address:ip_match(Peer, Allowlist).


% Extra host sanitization as cowboy is too lenient.
% Cowboy did already do the lowercasing of the hostname

-spec sanitize_host(Host) -> Result when
	Host :: binary(),
	Result :: binary().
sanitize_host(<<$[, _/binary>> = Host) ->
    % IPv6 address, sanitized by cowboy
    Host;
sanitize_host(Host) ->
    sanitize_host(Host, <<>>).

-spec sanitize_host(Host, Acc) -> Result when
	Host :: binary(),
	Acc ::  binary(),
	Result :: binary().
sanitize_host(<<>>, Acc) -> Acc;
sanitize_host(<<C, Rest/binary>>, Acc) when C >= $a, C =< $z -> sanitize_host(Rest, <<Acc/binary, C>>);
sanitize_host(<<C, Rest/binary>>, Acc) when C >= $0, C =< $9 -> sanitize_host(Rest, <<Acc/binary, C>>);
sanitize_host(<<$-, Rest/binary>>, Acc) -> sanitize_host(Rest, <<Acc/binary, $->>);
sanitize_host(<<$., Rest/binary>>, Acc) -> sanitize_host(Rest, <<Acc/binary, $.>>);
sanitize_host(<<$:, _/binary>>, Acc) -> Acc;
sanitize_host(<<_, Rest/binary>>, Acc) -> sanitize_host(Rest, <<Acc/binary, $->>).

