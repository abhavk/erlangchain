-module(json_util).
-export([encode/1, decode/1]).

%%--- Encoder --------------------------------------------------------

encode(null)                      -> <<"null">>;
encode(true)                      -> <<"true">>;
encode(false)                     -> <<"false">>;
encode(N) when is_integer(N)      -> integer_to_binary(N);
encode(N) when is_float(N)        -> float_to_binary(N, [{decimals, 10}, compact]);
encode(B) when is_binary(B)       -> enc_str(B);
encode(L) when is_list(L)         -> enc_arr(L);
encode(M) when is_map(M)          -> enc_obj(M).

%% esc/1 is quadratic on large strings (each step copies the tail). For multi‑MB
%% payloads (e.g. base64 in LLM JSON), use a fast path when no escaping is needed.
enc_str(B) when is_binary(B) ->
    case json_string_must_escape(B) of
        true  -> <<"\"", (esc(B))/binary, "\"">>;
        false -> <<$", B/binary, $">>
    end.

json_string_must_escape(<<>>) -> false;
json_string_must_escape(<<$", _/binary>>) -> true;
json_string_must_escape(<<$\\, _/binary>>) -> true;
json_string_must_escape(<<C, _/binary>>) when C < 32 -> true;
json_string_must_escape(<<_, R/binary>>) -> json_string_must_escape(R).

esc(<<>>)                -> <<>>;
esc(<<$",  R/binary>>)   -> <<"\\\"",  (esc(R))/binary>>;
esc(<<$\\, R/binary>>)   -> <<"\\\\",  (esc(R))/binary>>;
esc(<<$\n, R/binary>>)   -> <<"\\n",   (esc(R))/binary>>;
esc(<<$\r, R/binary>>)   -> <<"\\r",   (esc(R))/binary>>;
esc(<<$\t, R/binary>>)   -> <<"\\t",   (esc(R))/binary>>;
esc(<<C, R/binary>>) when C < 32 ->
    H = list_to_binary(io_lib:format("\\u~4.16.0B", [C])),
    <<H/binary, (esc(R))/binary>>;
esc(<<C/utf8, R/binary>>) ->
    E = <<C/utf8>>,
    <<E/binary, (esc(R))/binary>>.

enc_arr(Items) ->
    iolist_to_binary([$[, lists:join($,, [encode(I) || I <- Items]), $]]).

enc_obj(Map) ->
    Pairs = maps:to_list(Map),
    iolist_to_binary([${, lists:join($,, [enc_kv(K, V) || {K, V} <- Pairs]), $}]).

enc_kv(K, V) when is_atom(K)   -> enc_kv(atom_to_binary(K), V);
enc_kv(K, V) when is_binary(K) -> [enc_str(K), $:, encode(V)].

%%--- Decoder --------------------------------------------------------

decode(Bin) when is_binary(Bin) ->
    {Val, _} = val(ws(Bin)),
    Val.

ws(<<C, R/binary>>) when C =:= $\s; C =:= $\t; C =:= $\n; C =:= $\r -> ws(R);
ws(B) -> B.

val(<<"null",  R/binary>>)  -> {null,  R};
val(<<"true",  R/binary>>)  -> {true,  R};
val(<<"false", R/binary>>)  -> {false, R};
val(<<$", _/binary>> = B)   -> dec_str(B);
val(<<$[, _/binary>> = B)   -> dec_arr(B);
val(<<${, _/binary>> = B)   -> dec_obj(B);
val(<<C, _/binary>> = B) when C =:= $-; C >= $0, C =< $9 -> dec_num(B).

%% Strings

dec_str(<<$", R/binary>>) -> str_acc(R, <<>>).

str_acc(<<$",  R/binary>>, A) -> {A, R};
str_acc(<<$\\, $",  R/binary>>, A) -> str_acc(R, <<A/binary, $">>);
str_acc(<<$\\, $\\, R/binary>>, A) -> str_acc(R, <<A/binary, $\\>>);
str_acc(<<$\\, $/,  R/binary>>, A) -> str_acc(R, <<A/binary, $/>>);
str_acc(<<$\\, $n,  R/binary>>, A) -> str_acc(R, <<A/binary, $\n>>);
str_acc(<<$\\, $r,  R/binary>>, A) -> str_acc(R, <<A/binary, $\r>>);
str_acc(<<$\\, $t,  R/binary>>, A) -> str_acc(R, <<A/binary, $\t>>);
str_acc(<<$\\, $b,  R/binary>>, A) -> str_acc(R, <<A/binary, $\b>>);
str_acc(<<$\\, $f,  R/binary>>, A) -> str_acc(R, <<A/binary, $\f>>);
str_acc(<<$\\, $u, H1, H2, H3, H4,
          $\\, $u, L1, L2, L3, L4, R/binary>>, A) ->
    Hi = list_to_integer([H1, H2, H3, H4], 16),
    Lo = list_to_integer([L1, L2, L3, L4], 16),
    case Hi >= 16#D800 andalso Hi =< 16#DBFF
         andalso Lo >= 16#DC00 andalso Lo =< 16#DFFF of
        true ->
            CP = (Hi - 16#D800) * 16#400 + (Lo - 16#DC00) + 16#10000,
            str_acc(R, <<A/binary, CP/utf8>>);
        false ->
            str_acc(<<$\\, $u, L1, L2, L3, L4, R/binary>>,
                    <<A/binary, Hi/utf8>>)
    end;
str_acc(<<$\\, $u, H1, H2, H3, H4, R/binary>>, A) ->
    CP = list_to_integer([H1, H2, H3, H4], 16),
    str_acc(R, <<A/binary, CP/utf8>>);
str_acc(<<C/utf8, R/binary>>, A) ->
    str_acc(R, <<A/binary, C/utf8>>).

%% Arrays

dec_arr(<<$[, R/binary>>) ->
    case ws(R) of
        <<$], R2/binary>> -> {[], R2};
        R1 -> arr_elems(R1, [])
    end.

arr_elems(B, Acc) ->
    {V, R} = val(ws(B)),
    case ws(R) of
        <<$], R2/binary>> -> {lists:reverse([V | Acc]), R2};
        <<$,, R2/binary>> -> arr_elems(R2, [V | Acc])
    end.

%% Objects

dec_obj(<<${, R/binary>>) ->
    case ws(R) of
        <<$}, R2/binary>> -> {#{}, R2};
        R1 -> obj_pairs(R1, #{})
    end.

obj_pairs(B, Acc) ->
    {Key, R}  = dec_str(ws(B)),
    <<$:, R2/binary>> = ws(R),
    {Val, R3} = val(ws(R2)),
    Acc2 = maps:put(Key, Val, Acc),
    case ws(R3) of
        <<$}, R4/binary>> -> {Acc2, R4};
        <<$,, R4/binary>> -> obj_pairs(R4, Acc2)
    end.

%% Numbers

dec_num(B) ->
    {Raw, R} = take_num(B, <<>>),
    {parse_num(Raw), R}.

take_num(<<C, R/binary>>, A)
  when C >= $0, C =< $9; C =:= $-; C =:= $+; C =:= $.; C =:= $e; C =:= $E ->
    take_num(R, <<A/binary, C>>);
take_num(R, A) -> {A, R}.

parse_num(Raw) ->
    S = binary_to_list(Raw),
    HasDot = lists:member($., S),
    HasExp = lists:member($e, S) orelse lists:member($E, S),
    case {HasDot, HasExp} of
        {false, false} -> list_to_integer(S);
        {true,  _}     -> list_to_float(S);
        {false, true}  ->
            {Pre, [E | Post]} =
                lists:splitwith(fun(C) -> C =/= $e andalso C =/= $E end, S),
            list_to_float(Pre ++ ".0" ++ [E | Post])
    end.
