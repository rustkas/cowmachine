%% @author Justin Sheehy <justin@basho.com>
%% @author Andy Gross <andy@basho.com>
%% @copyright 2007-2008 Basho Technologies
%%
%% @doc Utilities for parsing, quoting, and negotiation.
%% @end
%%
%%    Licensed under the Apache License, Version 2.0 (the "License");
%%    you may not use this file except in compliance with the License.
%%    You may obtain a copy of the License at
%%
%%        http://www.apache.org/licenses/LICENSE-2.0
%%
%%    Unless required by applicable law or agreed to in writing, software
%%    distributed under the License is distributed on an "AS IS" BASIS,
%%    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%    See the License for the specific language governing permissions and
%%    limitations under the License.

-module(cowmachine_util).

-export([is_valid_header/1, is_valid_header_value/1, valid_location/1]).
-export([parse_qs/1]).
-export([convert_request_date/1]).
-export([choose_media_type_provided/2]).
-export([is_media_type_accepted/2]).
-export([choose_media_type_accepted/2]).
-export([choose_charset/2]).
-export([choose_encoding/2]).
-export([parse_header/1]).
-export([normalize_content_type/1]).
-export([format_content_type/1]).
-export([quoted_string/1]).
-export([split_quoted_strings/1]).


%% @doc Check header valid characters, 
%% see <a href="https://www.ietf.org/rfc/rfc822.txt">rfc822</a>

-spec is_valid_header(Header) -> Result when
	Header :: binary(),
	Result :: boolean().
is_valid_header(<<>>) -> false;
is_valid_header(H) -> is_valid_header_1(H).

-spec is_valid_header_1(Header) -> Result when
	Header :: binary(),
	Result :: boolean().
is_valid_header_1(<<>>) -> true;
is_valid_header_1(<<$:, _/binary>>) -> false;
is_valid_header_1(<<C, _/binary>>) when C >= $A, C =< $Z -> false;
is_valid_header_1(<<C, R/binary>>) when C >= 33, C =< 126 -> is_valid_header_1(R);
is_valid_header_1(_) -> false.

%% @doc Check if the given value is acceptaple for a http header value.

-spec is_valid_header_value(Header) -> Result when
	Header :: binary(),
	Result :: boolean().
is_valid_header_value(<<>>) -> true;
is_valid_header_value(<<13, _/binary>>) -> false;
is_valid_header_value(<<10, _/binary>>) -> false;
is_valid_header_value(<<C, R/binary>>) when C =< 127 -> is_valid_header_value(R);
is_valid_header_value(_) -> false.


%% @doc Check if the given location is safe to use as a location header. This is
%% uses as a defense against urls with scripts. The test is quite strict and will
%% drop values that might have been acceptable.

-spec valid_location(Location) -> Result when
	Location :: binary(),
	Result :: {true, binary()} | false.
valid_location(Location) ->
    case is_valid_header_value(Location) of
        true ->
            case z_html:noscript(Location, false) of
                <<"#script-removed">> -> false;
                <<>> -> false;
                Loc -> {true, Loc}
            end;
        false ->
            false
    end.

%% @doc Parse the HTTP date (IMF-fixdate, rfc850, asctime).

-spec convert_request_date(Date) -> Result when
	Date :: binary(),
	Result :: calendar:datetime().
convert_request_date(Date) ->
    try
        cow_date:parse_date(Date)
    catch
        error:_ -> bad_date
    end.

%% @doc Match the `Accept' request header with `content_types_provided'.<br/>
%% Return the `Content-Type' for the response.<br/>
%% If there is no acceptable/available match, return the atom `none'.<br/>
%% `AcceptHead' is the value of the request's `Accept' header.<br/>
%% `Provided' is a list of media types the controller can provide:
%% <ul>
%% 	<li>a binary e.g. — `<<"text/html">>'<br/></li>
%% 	<li>a binary and parameters e.g. — `{<<"text/html">>,[{<<"level">>,<<"1">>}]}'</li>
%% 	<li>two binaries e.g. `{<<"text">>, <<"html">>}'</li>
%% 	<li>two binaries and parameters e.g. — `{<<"text">>,<<"html">>,[{<<"level">>,<<"1">>}]}'</li>
%% </ul>
%% (the plain string case with no parameters is much more common)

-spec choose_media_type_provided(Provided, AcceptHead) -> Result when
	Provided :: MediaTypes,
	MediaTypes :: [MediaType],
	MediaType :: cow_http_hd:media_type(),
	AcceptHead :: binary(),
	Result :: cow_http_hd:media_type() | none.
choose_media_type_provided(Provided, AcceptHead) when is_list(Provided), is_binary(AcceptHead) ->
    Requested = accept_header_to_media_types(AcceptHead),
    Prov1 = normalize_provided(Provided),
    choose_media_type_provided_1(Prov1, Requested).

-spec choose_media_type_provided_1(Provided, Requested) -> Result when
	Provided :: list(), 
	Requested :: [cow_http_hd:media_type()],
	Result :: cow_http_hd:media_type() | none.
choose_media_type_provided_1(_Provided, []) ->
    none;
choose_media_type_provided_1(Provided, [H|T]) ->
    case media_match_provided(H, Provided) of
        none -> choose_media_type_provided_1(Provided, T);
        CT -> CT
    end.

% @doc Return the first matching content type or the atom `none'.

-spec media_match_provided(MediaTypes, Provided) -> Result when
	MediaTypes :: {binary(), binary()} | {binary(), binary()} | any(), 
	Provided :: list(),
	Result :: cow_http_hd:media_type() | none.
media_match_provided(_, []) ->
    none;
media_match_provided({<<"*">>, <<"*">>, []}, [H|_]) ->
    H;
media_match_provided({TypeA, TypeB, Params}, Provided) ->
    case lists:dropwhile(
                fun({PT1,PT2,PP}) ->
                    not (media_type_match(TypeA, TypeB, PT1, PT2)
                         andalso media_params_match(Params, PP))
                end,
                Provided)
    of
        [] -> none;
        [M|_] -> M
    end.

%% @doc Match the `Content-Type' request header with `content_types_accepted' against.

-spec is_media_type_accepted(ContentTypesAccepted, ContentTypeReqHeader) -> Result when
	ContentTypesAccepted :: list(), 
	ContentTypeReqHeader :: cow_http_hd:media_type(),
	Result :: boolean().
is_media_type_accepted([], _ReqHeader) ->
    true;
is_media_type_accepted(ContentTypesAccepted, ContentTypeReqHeader) when is_list(ContentTypesAccepted), is_tuple(ContentTypeReqHeader) ->
    ContentTypesAccepted1 = normalize_provided(ContentTypesAccepted),
    choose_media_type_accepted_1(ContentTypesAccepted1, ContentTypeReqHeader) =/= none.

-spec choose_media_type_accepted(ContentTypesAccepted, ReqHeader) -> Result when
	ContentTypesAccepted :: [cowmachine_req:media_type()], 
	ReqHeader :: cow_http_hd:media_type(),
	Result :: cowmachine_req:media_type() | none.
choose_media_type_accepted([], ReqHeader) ->
    ReqHeader;
choose_media_type_accepted(ContentTypesAccepted, ContentTypeReqHeader) when is_list(ContentTypesAccepted), is_tuple(ContentTypeReqHeader) ->
    ContentTypesAccepted1 = normalize_provided(ContentTypesAccepted),
    choose_media_type_accepted_1(ContentTypesAccepted1, ContentTypeReqHeader).

-spec choose_media_type_accepted_1(ContentTypesAccepted, ReqHeader) -> Result when
	ContentTypesAccepted :: [cowmachine_req:media_type()], 
	ReqHeader :: cow_http_hd:media_type(),
	Result :: cowmachine_req:media_type() | none.
choose_media_type_accepted_1([], _CTReq) ->
    none;
choose_media_type_accepted_1([{A1,A2,APs} = AT|T], {CT1,CT2,CTPs} = CTReq) ->
    case media_type_match(A1, A2, CT1, CT2) of
        true ->
            case media_params_match(CTPs, APs) of
                true ->
                    AT;
                false ->
                    choose_media_type_accepted_1(T, CTReq)
            end;
        false ->
            choose_media_type_accepted_1(T, CTReq)
    end.


-spec media_type_match(Req1, Req2, Prov1, Prov2) -> Result when
	Req1 :: binary(), 
	Req2 :: binary(), 
	Prov1 :: binary(), 
	Prov2 :: binary(),
	Result :: boolean().
media_type_match(Req1, Req2, Req1, Req2) -> true;
media_type_match(<<"*">>, <<"*">>, _Prov1, _Prov2) -> true;
media_type_match(Req1, <<"*">>, Req1, _Prov2) -> true;
media_type_match(_Req1, _Req2, _Prov1, _Prov2) -> false.

%% @doc Match the media parameters. Provided must be a subset of requested.
%%      There may not be a type in provided that is not in requested.

-spec media_params_match(ReqList, ProvList) -> Result when
	ReqList :: list(), 
	ProvList :: list(),
	Result :: boolean().
media_params_match(_ReqList, []) -> true;
media_params_match(ReqList, ReqList) -> true;
media_params_match(ReqList, ProvList) ->
    lists:all(
        fun(Prov) ->
            lists:member(Prov, ReqList)
        end,
        ProvList).
% @private
% @doc Given the value of an accept header, produce an ordered list based on the q-values.
% The first result being the highest-priority requested type.

-spec accept_header_to_media_types(HeadVal) -> Result when
	HeadVal :: binary(),
	Result :: [cow_http_hd:media_type()].
accept_header_to_media_types(HeadVal) ->
    try
        MTs = cow_http_hd:parse_accept(HeadVal),
        Sorted = lists:reverse(lists:keysort(2, MTs)),
        [ MType || {MType, _Prio, _Extra} <- Sorted ]
    catch
        _:_ -> []
    end.

-spec normalize_provided(Provided) -> Result when
	Provided :: [cowmachine_req:media_type()],
	Result :: cow_http_hd:media_type().
normalize_provided(Provided) ->
    [ normalize_content_type(X) || X <- Provided ].

-spec normalize_content_type(Type) -> Result when
	Type :: cowmachine_req:media_type(),
	Result :: cow_http_hd:media_type().
normalize_content_type(Type) when is_binary(Type) ->
    cow_http_hd:parse_content_type(Type);
normalize_content_type({Type,Params}) when is_binary(Type), is_list(Params) ->
    {T1,T2, _} = cow_http_hd:parse_content_type(Type),
    {T1, T2, Params};
normalize_content_type({Type1,Type2}) when is_binary(Type1), is_binary(Type2) ->
    {Type1, Type2, []};
normalize_content_type({Type1,Type2,Params}) when is_binary(Type1), is_binary(Type2), is_list(Params) ->
    {Type1, Type2, Params}.

-spec format_content_type(MediaType) -> Result when
	MediaType :: cow_http_hd:media_type(),
	Result :: binary().
format_content_type({T1, T2, []}) ->
    <<T1/binary, $/, T2/binary>>;
format_content_type({T1, T2, Params}) ->
    ParamsBin = [ [$;, Param, $=, Value] || {Param,Value} <- Params ],
    iolist_to_binary([T1, $/, T2, ParamsBin]).

%% @doc Select the best fitting character set or `none'

-spec choose_charset(CSets, AccCharHdr) -> Result when
	CSets :: [binary()], 
	AccCharHdr :: binary(),
	Result :: none | binary().
choose_charset(CSets, AccCharHdr) ->
    do_choose(CSets, AccCharHdr, <<"utf-8">>).

%% @doc Select the best fitting encoding or `none'

-spec choose_encoding(Encs, AccEncHdr) -> Result when
	Encs :: [binary()], 
	AccEncHdr :: binary(),
	Result :: none | binary().
choose_encoding(Encs, AccEncHdr) ->
    do_choose(Encs, AccEncHdr, <<"identity">>).

-spec do_choose(Choices, Header, Default) -> Result when
	Choices :: [binary()],
	Header :: binary(),
	Default :: binary(),
	Result :: none | binary().
do_choose(Choices, Header, Default) ->
    try
        Accepted = cow_http_hd:parse_accept_encoding(Header),
        Accepted1 = lists:reverse(lists:keysort(2, Accepted)),
        DefaultPrio = [P || {C,P} <- Accepted1, C =:= Default],
        StarPrio = [P || {C,P} <- Accepted1, C =:= <<"*">>],
        DefaultOkay = case DefaultPrio of
            [] ->
                case StarPrio of
                    [0] -> no;
                    _ -> yes
                end;
            [0] -> no;
            _ -> yes
        end,
        AnyOkay = case StarPrio of
            [] -> no;
            [0] -> no;
            _ -> yes
        end,
        do_choose(Default, DefaultOkay, AnyOkay, Choices, Accepted)
    catch
        _:_ ->
            Default
    end.

-spec do_choose(Default, DefaultOkay, AnyOkay, Choices, Accepted) -> Result when
	Default :: binary(),
	DefaultOkay :: yes | no,
	AnyOkay :: yes | no,
	Choices :: list(), 
	Accepted :: list(),
	Result :: binary() | none.
do_choose(_Default, _DefaultOkay, _AnyOkay, [], _Accepted) ->
    none;
do_choose(_Default, _DefaultOkay, yes, [Choice|_], []) ->
    Choice;
do_choose(Default, yes, no, Choices, []) ->
    case lists:member(Default, Choices) of
        true -> Default;
        _ -> none
    end;
do_choose(_Default, no, no, _Choices, []) ->
    none;
do_choose(Default, DefaultOkay, AnyOkay, Choices, [{Acc,0}|AccRest]) ->
    do_choose(Default, DefaultOkay, AnyOkay, lists:delete(Acc, Choices), AccRest);
do_choose(Default, DefaultOkay, AnyOkay, Choices, [{Acc,_Prio}|AccRest]) ->
    case lists:member(Acc, Choices) of
        true -> Acc;
        false -> do_choose(Default, DefaultOkay, AnyOkay, Choices, AccRest)
    end.


%% The percent decoding is inlined to greatly improve the performance
%% by avoiding copying binaries twice (once for extracting, once for
%% decoding) instead of just extracting the proper representation.
%%
%% Copyright (c) 2013-2015, Loïc Hoguin <essen@ninenines.eu>
%%
%% Permission to use, copy, modify, and/or distribute this software for any
%% purpose with or without fee is hereby granted, provided that the above
%% copyright notice and this permission notice appear in all copies.
%%
%% THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
%% WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
%% MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
%% ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
%% WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
%% ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
%% OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
%%

%% @doc Parse an `application/x-www-form-urlencoded' string.<br/>
%% See also <a href="https://www.w3.org/TR/html401/interact/forms.html#didx-applicationx-www-form-urlencoded">specification</a>.

-spec parse_qs(String) -> Result when
	String :: binary(),
	Result :: list({binary(),binary()}).
parse_qs(<<>>) ->
    [];
parse_qs(Qs) ->
    parse_qs_name(Qs, [], <<>>).

%% @throws invalid_percent_encoding

-spec parse_qs_name(String, Acc, Name) -> Result when
	String :: binary(),
	Acc :: list(),
	Name :: binary(),
	Result :: list({binary(),binary()}).
parse_qs_name(<< $%, H, L, Rest/binary >>, Acc, Name) ->
    C = (unhex(H) bsl 4 bor unhex(L)),
    parse_qs_name(Rest, Acc, << Name/binary, C >>);
parse_qs_name(<< $+, Rest/binary >>, Acc, Name) ->
    parse_qs_name(Rest, Acc, << Name/binary, " " >>);
parse_qs_name(<< $=, _/binary >>, _Acc, <<>>) ->
    throw(invalid_qs_name);
parse_qs_name(<< $=, Rest/binary >>, Acc, Name) ->
    parse_qs_value(Rest, Acc, Name, <<>>);
parse_qs_name(<< $&, Rest/binary >>, Acc, Name) ->
    case Name of
        <<>> -> parse_qs_name(Rest, Acc, <<>>);
        _ -> parse_qs_name(Rest, [{Name, <<>>}|Acc], <<>>)
    end;
parse_qs_name(<< C, Rest/binary >>, Acc, Name) when C =/= $% ->
    parse_qs_name(Rest, Acc, << Name/binary, C >>);
parse_qs_name(<<>>, Acc, Name) ->
    case Name of
        <<>> -> lists:reverse(Acc);
        _ -> lists:reverse([{Name, <<>>}|Acc])
    end;
parse_qs_name(_Rest, _Acc, _Name) ->
    throw(invalid_percent_encoding).

%% @throws invalid_percent_encoding

-spec parse_qs_value(String, Acc, Name, Value) -> Result when
	String :: binary(),
	Acc :: list(),
	Name :: binary(),
	Value :: binary(),
	Result :: list({binary(),binary()}).
parse_qs_value(<< $%, H, L, Rest/binary >>, Acc, Name, Value) ->
    C = (unhex(H) bsl 4 bor unhex(L)),
    parse_qs_value(Rest, Acc, Name, << Value/binary, C >>);
parse_qs_value(<< $+, Rest/binary >>, Acc, Name, Value) ->
    parse_qs_value(Rest, Acc, Name, << Value/binary, " " >>);
parse_qs_value(<< $&, Rest/binary >>, Acc, Name, Value) ->
    parse_qs_name(Rest, [{Name, Value}|Acc], <<>>);
parse_qs_value(<< C, Rest/binary >>, Acc, Name, Value) when C =/= $% ->
    parse_qs_value(Rest, Acc, Name, << Value/binary, C >>);
parse_qs_value(<<>>, Acc, Name, Value) ->
    lists:reverse([{Name, Value}|Acc]);
parse_qs_value(_Rest, _Acc, _Name, _Value) ->
    throw(invalid_percent_encoding).

%% @throws invalid_percent_encoding

-spec unhex(Char) -> Result when
	Char :: char(),
	Result :: 1..15.
unhex($0) ->  0;
unhex($1) ->  1;
unhex($2) ->  2;
unhex($3) ->  3;
unhex($4) ->  4;
unhex($5) ->  5;
unhex($6) ->  6;
unhex($7) ->  7;
unhex($8) ->  8;
unhex($9) ->  9;
unhex($A) -> 10;
unhex($B) -> 11;
unhex($C) -> 12;
unhex($D) -> 13;
unhex($E) -> 14;
unhex($F) -> 15;
unhex($a) -> 10;
unhex($b) -> 11;
unhex($c) -> 12;
unhex($d) -> 13;
unhex($e) -> 14;
unhex($f) -> 15;
unhex(_) -> throw(invalid_percent_encoding).


%% author Bob Ippolito <bob@mochimedia.com>
%% copyright 2007 Mochi Media, Inc.
%% @doc  Parse a Content-Type like header, return the main Content-Type
%%       and a property list of options.

-spec parse_header(String) -> Result when
	String :: binary(),
	Result :: {binary(), list({binary(),binary()})}.
parse_header(String) ->
    %% TODO: This is exactly as broken as Python's cgi module.
    %%       Should parse properly like mochiweb_cookies.
    [Type | Parts] = [z_string:trim(S) || S <- binary:split(String, <<";">>, [global])],
    F = fun (S, Acc) ->
            case binary:split(S, <<"=">>) of
                [_] -> Acc;
                [<<>>, _] -> Acc;
                [_, <<>>] -> Acc;
                [Name, Value] ->
                    [{z_string:to_lower(z_string:trim(Name)), unquote_header(z_string:trim(Value))} | Acc]
            end
        end,
    {z_string:to_lower(Type), lists:foldr(F, [], Parts)}.

-spec unquote_header(Header) -> Result when
	Header :: binary(),
	Result :: binary().
unquote_header(<<$", Rest/binary>>) ->
    unquote_header(Rest, <<>>);
unquote_header(S) ->
    S.

-spec unquote_header(Header, Acc) -> Result when
	Header :: binary(),
	Acc :: binary(),
	Result :: binary().
unquote_header(<<>>, Acc) -> Acc;
unquote_header(<<$">>, Acc) -> Acc;
unquote_header(<<$\\, C, Rest/binary>>, Acc) ->
    unquote_header(Rest, <<Acc/binary, C>>);
unquote_header(<<C, Rest/binary>>, Acc) ->
    unquote_header(Rest, <<Acc/binary, C>>).


-spec quoted_string(String) -> Result when
	String :: binary(),
	Result :: binary().
quoted_string(<<$", _Rest/binary>> = Str) ->
    Str;
quoted_string(Str) ->
    escape_quotes(Str, <<$">>).                % Initialize Acc with opening quote

-spec escape_quotes(String, Acc) -> Result when
	String :: binary(), 
	Acc :: binary(),
	Result :: binary().
escape_quotes(<<>>, Acc) ->
    <<Acc/binary, $">>;                              % Append final quote
escape_quotes(<<$\\, Char, Rest/binary>>, Acc) ->
    escape_quotes(Rest, <<Acc/binary, $\\, Char>>);  % Any quoted char should be skipped
escape_quotes(<<$", Rest/binary>>, Acc) ->
    escape_quotes(Rest, <<Acc/binary, $\\, $">>);    % Unquoted quotes should be escaped
escape_quotes(<<Char, Rest/binary>>, Acc) ->
    escape_quotes(Rest, <<Acc/binary, Char>>).


-spec split_quoted_strings(String) -> Result when
	String :: binary(),
	Result :: [binary()].
split_quoted_strings(Str) ->
    split_quoted_strings(Str, []).

-spec split_quoted_strings(String, Acc) -> Result when
	String :: binary(),
	Acc :: [binary()],
	Result :: [binary()].
split_quoted_strings(<<>>, Acc) ->
    lists:reverse(Acc);
split_quoted_strings(<<$", Rest/binary>>, Acc) ->
    {Str, Cont} = unescape_quoted_string(Rest, <<>>),
    split_quoted_strings(Cont, [Str | Acc]);
split_quoted_strings(<<_Skip, Rest/binary>>, Acc) ->
    split_quoted_strings(Rest, Acc).

-spec unescape_quoted_string(String, Acc) -> Result when
	String :: binary(),
	Acc :: bitstring(),
	Result :: {bitstring(),binary()}.
unescape_quoted_string(<<>>, Acc) ->
    {Acc, <<>>};
unescape_quoted_string(<<$\\, Char, Rest/binary>>, Acc) -> % Any quoted char should be unquoted
    unescape_quoted_string(Rest, <<Acc/binary, Char>>);
unescape_quoted_string(<<$", Rest/binary>>, Acc) ->        % Quote indicates end of this string
    {Acc, Rest};
unescape_quoted_string(<<Char, Rest/binary>>, Acc) ->
    unescape_quoted_string(Rest, <<Acc/binary, Char>>).
