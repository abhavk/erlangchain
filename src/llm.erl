-module(llm).
-export([chat/1, chat/3, chat/4, chat/5, chat/6, model_for/2]).
-export_type([datasource/0]).

-define(ANTHROPIC_URL, "https://api.anthropic.com/v1/messages").
-define(OPENAI_RESPONSES_URL, "https://api.openai.com/v1/responses").
-define(ANTHROPIC_VER, "2023-06-01").
-define(MAX_TOKENS, 16384).
-define(TIMEOUT_MS, 300000).

-define(ANTHROPIC_BIG,   "claude-sonnet-4-20250514").
-define(ANTHROPIC_SMALL, "claude-haiku-3-5-20241022").
-define(OPENAI_BIG,      "gpt-5.6-terra").
-define(OPENAI_SMALL,    "gpt-5.6-luna").

%% -------------------------------------------------------------------
%% Public API
%%
%%   chat(Provider, Size, Messages)              -> {ok, Resp} | {error, _}
%%   chat(Provider, Size, Messages, Tools)       -> {ok, Resp} | {error, _}
%%   chat(Provider, Size, Messages, Tools, Opts) -> {ok, Resp} | {error, _}
%%   chat(Provider, Size, Messages, Tools, Datasource, Opts)
%%                                                -> {ok, Resp} | {error, _}
%%
%% Provider = anthropic | openai
%% Size     = big | small
%% Messages = [#{role => ..., content => ...} | #{role => user, parts => [...]} | ...]
%% User multimodal: #{role => user, parts => [{text, _} | {image_base64, Mime, B64}]}
%% Tools    = [#{name => binary(), description => binary(), parameters => map()}]
%% Datasource = none | binary()  OpenAI vector store id; Anthropic does not support it.
%% Opts     = #{model => string(), reasoning_effort => atom()}   optional overrides
%%            reasoning_effort: OpenAI Responses API only; sent as reasoning.effort.
%%            Default for Provider=openai, Size=big is medium; omit by overriding in Opts if needed.
%%
%% OpenAI uses POST /v1/responses (not chat/completions); tools + reasoning use this API.
%%
%% Response = #{role => assistant, content => binary(), tool_calls => [...],
%%              usage => #{in => integer(), out => integer(), cache_read => integer(),
%%                         reasoning => integer()}}
%%              reasoning: OpenAI Responses only; output-side reasoning_tokens (subset of out).
%% Each tool call = #{id => binary(), name => binary(), input => map()}
%%
%% To continue a multi-turn conversation, append the response to your
%% messages list, then add tool results as:
%%   #{role => tool_result, tool_use_id => Id, content => ResultBin}
%% -------------------------------------------------------------------

-type datasource() :: none | binary().

chat(Messages) ->
    chat(openai, small, Messages, []).

chat(Provider, Size, Messages) ->
    chat(Provider, Size, Messages, []).

chat(Provider, Size, Messages, Tools) ->
    chat(Provider, Size, Messages, Tools, #{}).

chat(Provider, Size, Messages, Tools, Opts) ->
    chat(Provider, Size, Messages, Tools, none, Opts).

-spec chat(anthropic | openai, big | small, [map()], [map()], datasource(), map()) ->
    {ok, map()} | {error, term()}.
chat(anthropic, Size, Messages, Tools, none, Opts) ->
    anthropic_chat(Size, Messages, Tools, Opts);
chat(anthropic, _Size, _Messages, _Tools, Datasource, _Opts)
  when is_binary(Datasource) ->
    {error, {unsupported_feature, datasource}};
chat(openai, Size, Messages, Tools, Datasource, Opts)
  when Datasource =:= none; is_binary(Datasource) ->
    openai_chat(Size, Messages, Tools, Datasource, Opts).

default_model(anthropic, big)   -> ?ANTHROPIC_BIG;
default_model(anthropic, small) -> ?ANTHROPIC_SMALL;
default_model(openai, big)      -> ?OPENAI_BIG;
default_model(openai, small)    -> ?OPENAI_SMALL.

%% Public: returns the actual model id that chat/3..4 will hit for a given
%% Provider/Size pair (no Opts overrides, since the agent never sets any).
%% Useful for logging the real model name in training transcripts.
model_for(Provider, Size) ->
    default_model(Provider, Size).

%%--- Anthropic ------------------------------------------------------

anthropic_chat(Size, Messages, Tools, Opts) ->
    ensure_started(),
    Key = require_env("ANTHROPIC_API_KEY"),
    Model = maps:get(model, Opts, default_model(anthropic, Size)),
    {System, Msgs} = extract_system(Messages),
    Body = anthropic_body(Model, System,
                          [anthropic_msg(M) || M <- Msgs],
                          [anthropic_tool(T) || T <- Tools]),
    Headers = [{"x-api-key", Key},
               {"anthropic-version", ?ANTHROPIC_VER}],
    case post(?ANTHROPIC_URL, Headers, Body) of
        {ok, Resp} -> {ok, parse_anthropic(Resp)};
        Err        -> Err
    end.

anthropic_body(Model, System, Msgs, Tools) ->
    Base = #{<<"model">>      => to_bin(Model),
             <<"max_tokens">> => ?MAX_TOKENS,
             <<"messages">>   => Msgs},
    B1 = case System of
             <<>> -> Base;
             _    -> Base#{<<"system">> => System}
         end,
    B2 = case Tools of
             [] -> B1;
             _  -> B1#{<<"tools">> => Tools}
         end,
    json_util:encode(B2).

extract_system(Messages) ->
    case lists:partition(fun(M) -> maps:get(role, M) =:= system end, Messages) of
        {[],              Rest} -> {<<>>, Rest};
        {[#{content := C} | _], Rest} -> {to_bin(C), Rest}
    end.

anthropic_msg(#{role := tool_result, tool_use_id := Id, content := C}) ->
    #{<<"role">>    => <<"user">>,
      <<"content">> => [#{<<"type">>        => <<"tool_result">>,
                          <<"tool_use_id">> => to_bin(Id),
                          <<"content">>     => to_bin(C)}]};
anthropic_msg(#{role := user, parts := Parts}) ->
    #{<<"role">> => <<"user">>,
      <<"content">> => [anthropic_user_part(P) || P <- Parts]};
anthropic_msg(#{role := Role} = M) ->
    Text  = maps:get(content, M, <<>>),
    Calls = maps:get(tool_calls, M, []),
    case Calls of
        [] ->
            #{<<"role">> => atom_to_binary(Role), <<"content">> => to_bin(Text)};
        _ ->
            TextBlocks = case Text of
                <<>> -> [];
                _    -> [#{<<"type">> => <<"text">>, <<"text">> => to_bin(Text)}]
            end,
            ToolBlocks = [#{<<"type">>  => <<"tool_use">>,
                            <<"id">>    => to_bin(maps:get(id, TC)),
                            <<"name">>  => to_bin(maps:get(name, TC)),
                            <<"input">> => maps:get(input, TC)}
                          || TC <- Calls],
            #{<<"role">>    => atom_to_binary(Role),
              <<"content">> => TextBlocks ++ ToolBlocks}
    end.

anthropic_tool(#{name := N, description := D, parameters := P}) ->
    #{<<"name">>         => to_bin(N),
      <<"description">>  => to_bin(D),
      <<"input_schema">> => P}.

parse_anthropic(Resp) ->
    Blocks = maps:get(<<"content">>, Resp, []),
    {Text, Calls} = lists:foldl(
        fun(Block, {TAcc, CAcc}) ->
            case maps:get(<<"type">>, Block) of
                <<"text">> ->
                    {<<TAcc/binary, (maps:get(<<"text">>, Block))/binary>>, CAcc};
                <<"tool_use">> ->
                    Call = #{id    => maps:get(<<"id">>, Block),
                             name  => maps:get(<<"name">>, Block),
                             input => maps:get(<<"input">>, Block)},
                    {TAcc, CAcc ++ [Call]}
            end
        end, {<<>>, []}, Blocks),
    Usage = parse_anthropic_usage(Resp),
    #{role => assistant, content => Text, tool_calls => Calls, usage => Usage}.

%%--- OpenAI ---------------------------------------------------------

openai_chat(Size, Messages, Tools, Datasource, Opts) ->
    ensure_started(),
    Key = require_env("OPENAI_API_KEY"),
    Opts1 = case Size of
                big -> maps:merge(#{reasoning_effort => medium}, Opts);
                _   -> Opts
            end,
    Model = maps:get(model, Opts1, default_model(openai, Size)),
    InputItems = messages_to_responses_input(Messages),
    Body = openai_responses_body(Model, InputItems, Tools, Datasource, Opts1),
    Headers = [{"authorization", "Bearer " ++ Key}],
    case post(?OPENAI_RESPONSES_URL, Headers, Body) of
        {ok, Resp} -> {ok, parse_openai_response(Resp)};
        Err        -> Err
    end.

openai_responses_body(Model, InputItems, Tools, Datasource, Opts) ->
    Base0 = #{<<"model">> => to_bin(Model),
              <<"input">> => InputItems,
              <<"max_output_tokens">> => ?MAX_TOKENS},
    RequestTools = [openai_responses_tool(T) || T <- Tools]
                   ++ openai_datasource_tools(Datasource),
    Base1 = case RequestTools of
                [] -> Base0;
                Ts ->
                    Base0#{<<"tools">> => Ts,
                            <<"tool_choice">> => <<"auto">>}
            end,
    Base2 = case maps:get(reasoning_effort, Opts, undefined) of
                 undefined -> Base1;
                 Eff       -> Base1#{<<"reasoning">> => #{<<"effort">> => to_bin(Eff)}}
             end,
    json_util:encode(Base2).

%% Flatten internal messages into Responses API input items (stateless multi-turn).
messages_to_responses_input(Messages) ->
    lists:flatten([message_to_responses_input(M) || M <- Messages]).

message_to_responses_input(#{role := system} = M) ->
    [easy_input_message(<<"system">>, maps:get(content, M))];
message_to_responses_input(#{role := user, parts := Parts}) ->
    [#{<<"role">> => <<"user">>,
       <<"content">> => [responses_input_part(P) || P <- Parts]}];
message_to_responses_input(#{role := user} = M) ->
    [easy_input_message(<<"user">>, maps:get(content, M))];
message_to_responses_input(#{role := assistant} = M) ->
    Text  = maps:get(content, M, <<>>),
    Calls = maps:get(tool_calls, M, []),
    Msgs = case Text of
               <<>> -> [];
               T    -> [assistant_text_input_item(T)]
           end,
    Msgs ++ [function_call_input_item(TC) || TC <- Calls];
message_to_responses_input(#{role := tool_result, tool_use_id := Id, content := C}) ->
    [#{<<"type">>   => <<"function_call_output">>,
       <<"call_id">> => to_bin(Id),
       <<"output">>  => to_bin(C)}].

easy_input_message(Role, Content) when is_binary(Content); is_list(Content) ->
    #{<<"role">> => Role, <<"content">> => to_bin(Content)}.

assistant_text_input_item(Text) ->
    #{<<"role">> => <<"assistant">>,
      <<"content">> => [#{<<"type">> => <<"input_text">>, <<"text">> => to_bin(Text)}]}.

%% Replay model tool calls without output-only fields (call_id is what function_call_output uses).
function_call_input_item(#{id := CallId, name := Name, input := Input}) ->
    #{<<"type">>      => <<"function_call">>,
      <<"call_id">>   => to_bin(CallId),
      <<"name">>      => to_bin(Name),
      <<"arguments">> => json_util:encode(Input)}.

openai_responses_tool(#{name := N, description := D, parameters := P}) ->
    #{<<"type">>        => <<"function">>,
      <<"name">>        => to_bin(N),
      <<"description">> => to_bin(D),
      <<"parameters">>  => P,
      <<"strict">>      => false}.

openai_datasource_tools(none) ->
    [];
openai_datasource_tools(VectorStoreId) when is_binary(VectorStoreId) ->
    [#{<<"type">> => <<"file_search">>,
       <<"vector_store_ids">> => [VectorStoreId]}].

responses_input_part({text, T}) ->
    #{<<"type">> => <<"input_text">>, <<"text">> => to_bin(T)};
responses_input_part({image_base64, Mime, B64}) ->
    Url = iolist_to_binary(["data:", to_bin(Mime), ";base64,", B64]),
    #{<<"type">> => <<"input_image">>, <<"image_url">> => Url}.

parse_openai_response(Resp) ->
    Out = maps:get(<<"output">>, Resp, []),
    {Text, Calls} = lists:foldl(fun fold_output_item/2, {<<>>, []}, Out),
    Usage = parse_openai_responses_usage(Resp),
    #{role => assistant, content => Text, tool_calls => Calls, usage => Usage}.

fold_output_item(Item, {TAcc, CAcc}) ->
    case maps:get(<<"type">>, Item, undefined) of
        <<"message">> ->
            T = extract_assistant_output_text(Item),
            {<<TAcc/binary, T/binary>>, CAcc};
        <<"function_call">> ->
            CallId = maps:get(<<"call_id">>, Item),
            Name = maps:get(<<"name">>, Item),
            ArgsBin = maps:get(<<"arguments">>, Item, <<"{}">>),
            Input = json_util:decode(ArgsBin),
            Call = #{id => CallId, name => Name, input => Input},
            {TAcc, CAcc ++ [Call]};
        _ ->
            {TAcc, CAcc}
    end.

extract_assistant_output_text(Item) ->
    Content = maps:get(<<"content">>, Item, []),
    lists:foldl(
        fun(B, Acc) ->
            case maps:get(<<"type">>, B, undefined) of
                <<"output_text">> ->
                    <<Acc/binary, (maps:get(<<"text">>, B, <<>>))/binary>>;
                _ ->
                    Acc
            end
        end, <<>>, Content).

parse_anthropic_usage(Resp) ->
    case maps:get(<<"usage">>, Resp, null) of
        null -> #{in => 0, out => 0, cache_read => 0, reasoning => 0};
        U    -> #{in         => maps:get(<<"input_tokens">>, U, 0),
                  out        => maps:get(<<"output_tokens">>, U, 0),
                  cache_read => maps:get(<<"cache_read_input_tokens">>, U, 0),
                  reasoning  => 0}
    end.

parse_openai_responses_usage(Resp) ->
    case maps:get(<<"usage">>, Resp, null) of
        null -> #{in => 0, out => 0, cache_read => 0, reasoning => 0};
        U    ->
            Cached = case maps:get(<<"input_tokens_details">>, U, null) of
                         null -> 0;
                         D    -> maps:get(<<"cached_tokens">>, D, 0)
                     end,
            Reasoning = case maps:get(<<"output_tokens_details">>, U, null) of
                           null -> 0;
                           D2   -> maps:get(<<"reasoning_tokens">>, D2, 0)
                       end,
            #{in         => maps:get(<<"input_tokens">>, U, 0),
              out        => maps:get(<<"output_tokens">>, U, 0),
              cache_read => Cached,
              reasoning  => Reasoning}
    end.

%%--- HTTP (inets) ---------------------------------------------------

ensure_started() ->
    load_dotenv(),
    application:ensure_all_started(inets),
    application:ensure_all_started(ssl).

load_dotenv() ->
    case file:read_file(".env") of
        {ok, Bin} ->
            Lines = string:split(binary_to_list(Bin), "\n", all),
            lists:foreach(fun set_env_line/1, Lines);
        {error, _} ->
            ok
    end.

set_env_line(Line) ->
    Trimmed = string:trim(Line),
    case Trimmed of
        []      -> ok;
        [$# | _] -> ok;
        _        ->
            case string:split(Trimmed, "=") of
                [Key, Val] -> os:putenv(string:trim(Key), string:trim(Val));
                _          -> ok
            end
    end.

post(Url, Headers, Body) ->
    Bin = iolist_to_binary(Body),
    case httpc:request(post,
            {Url, Headers, "application/json", Bin},
            [{ssl, [{verify, verify_none}]}, {timeout, ?TIMEOUT_MS}],
            [{body_format, binary}]) of
        {ok, {{_, S, _}, _, RespBody}} when S >= 200, S < 300 ->
            {ok, json_util:decode(RespBody)};
        {ok, {{_, S, _}, _, RespBody}} ->
            {error, {http, S, RespBody}};
        {error, Reason} ->
            {error, Reason}
    end.

anthropic_user_part({text, T}) ->
    #{<<"type">> => <<"text">>, <<"text">> => to_bin(T)};
anthropic_user_part({image_base64, Mime, B64}) ->
    #{<<"type">> => <<"image">>, <<"source">> => #{
        <<"type">> => <<"base64">>,
        <<"media_type">> => to_bin(Mime),
        <<"data">> => B64
    }}.

%%--- Helpers --------------------------------------------------------

require_env(Name) ->
    case os:getenv(Name) of
        false -> error({missing_env, Name});
        Val   -> Val
    end.

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L)   -> unicode:characters_to_binary(L);
to_bin(A) when is_atom(A)   -> atom_to_binary(A).
