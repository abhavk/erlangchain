-module(llm).
-export([chat/1, chat/3, chat/4, chat/5, chat/6, image/3, model_for/2,
         cost/3, cost/4]).
-export_type([datasource/0]).

-define(ANTHROPIC_URL, "https://api.anthropic.com/v1/messages").
-define(OPENAI_RESPONSES_URL, "https://api.openai.com/v1/responses").
-define(OPENROUTER_CHAT_URL, "https://openrouter.ai/api/v1/chat/completions").
-define(HUGGINGFACE_FAL_FLUX_DEV_URL,
        "https://router.huggingface.co/fal-ai/fal-ai/flux/dev").
-define(ANTHROPIC_VER, "2023-06-01").
-define(MAX_TOKENS, 16384).
-define(TIMEOUT_MS, 300000).
-define(FAL_POLL_MS, 500).

-define(ANTHROPIC_BIG,   "claude-opus-5-5").
-define(ANTHROPIC_SMALL, "claude-haiku-5-5").
-define(ANTHROPIC_FRONTIER, "fable-5").
-define(OPENAI_BIG,      "gpt-5.6-sol").
-define(OPENAI_SMALL,    "gpt-5.6-luna").
-define(OPENAI_FRONTIER, "gpt-6-astra").
-define(OPENSOURCE_BIG,  "z-ai/glm-5.2").
-define(OPENSOURCE_SMALL,"openai/gpt-oss-20b").
-define(OPENSOURCE_FRONTIER, "moonshotai/kimi-k3").

%% -------------------------------------------------------------------
%% Public API
%%
%%   chat(Provider, Size, Messages)              -> {ok, Resp} | {error, _}
%%   chat(Provider, Size, Messages, Tools)       -> {ok, Resp} | {error, _}
%%   chat(Provider, Size, Messages, Tools, Opts) -> {ok, Resp} | {error, _}
%%   chat(Provider, Size, Messages, Tools, Datasource, Opts)
%%                                                -> {ok, Resp} | {error, _}
%%   image(opensource, large, Prompt)              -> {ok, ImageResp} | {error, _}
%%
%% Provider = anthropic | openai | opensource
%% TierOrModel = frontier | big | small | string() | binary()
%% Messages = [#{role => ..., content => ...} | #{role => user, parts => [...]} | ...]
%% User multimodal: #{role => user, parts => [{text, _} | {image_base64, Mime, B64}]}
%% Tools    = [#{name => binary(), description => binary(), parameters => map()}]
%% Datasource = none | binary()  OpenAI vector store id; other providers do not support it.
%% Opts     = #{model => string(), reasoning_effort => atom(),
%%              pricing => boolean(), prices => map(),
%%              caching => five_minutes | one_hour | off}   optional overrides
%%            reasoning_effort: OpenAI and OpenRouter send reasoning.effort.
%%            Anthropic sends output_config.effort. Omitted means the provider
%%            default. Default for Provider=openai, Size=big is medium; omit by
%%            overriding in Opts if needed.
%%            pricing defaults to true. prices replaces llm_prices:list/0.
%%            caching defaults to five_minutes. Anthropic sends
%%            cache_control ephemeral ttl 5m or 1h. off sends no cache_control.
%%            OpenAI and OpenRouter accept the option and do not change the request.
%%
%% OpenAI uses POST /v1/responses (not chat/completions); tools + reasoning use this API.
%%
%% Response = #{role => assistant, content => binary(), tool_calls => [...],
%%              usage => #{in => integer(), out => integer(), cache_read => integer(),
%%                         cache_write => integer(), cache_write_1h => integer(),
%%                         reasoning => integer(), cost_usd => float()}}
%%              reasoning: subset of out. OpenAI and OpenRouter report reasoning_tokens.
%%              Anthropic reports output_tokens_details.thinking_tokens.
%%              cost_usd is present when pricing is on and a rate is known.
%%              cache_write and cache_write_1h: Anthropic only. cache_write_1h
%%              is the 1-hour portion of cache_write.
%%              An assistant map may also include thinking => [Block].
%%              Those blocks are sent back on the next turn.
%%              The field is left off when the model sent no thinking.
%%   cost(Provider, Model, Usage) -> {ok, CostUsd} | {error, unknown_model}
%%   cost(Provider, Model, Usage, Prices) -> same
%% Each tool call = #{id => binary(), name => binary(), input => map()}
%% ImageResp = #{image => binary(), content_type => binary()}
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

-spec chat(anthropic | openai | opensource | string() | binary(),
           frontier | big | small | string() | binary(),
           [map()], [map()], datasource(), map()) ->
    {ok, map()} | {error, term()}.
chat(Provider, TierOrModel, Messages, Tools, Datasource, Opts)
  when is_list(Provider); is_binary(Provider) ->
    chat(provider_atom(Provider), TierOrModel, Messages, Tools, Datasource, Opts);
chat(anthropic, Size, Messages, Tools, none, Opts) ->
    with_caching(Opts, fun(Strategy) ->
        anthropic_chat(Size, Messages, Tools, Opts, Strategy)
    end);
chat(anthropic, _Size, _Messages, _Tools, Datasource, _Opts)
  when is_binary(Datasource) ->
    {error, {unsupported_feature, datasource}};
chat(openai, Size, Messages, Tools, Datasource, Opts)
  when Datasource =:= none; is_binary(Datasource) ->
    with_caching(Opts, fun(_Strategy) ->
        openai_chat(Size, Messages, Tools, Datasource, Opts)
    end);
chat(opensource, Size, Messages, Tools, none, Opts) ->
    with_caching(Opts, fun(_Strategy) ->
        openrouter_chat(Size, Messages, Tools, Opts)
    end);
chat(opensource, _Size, _Messages, _Tools, Datasource, _Opts)
  when is_binary(Datasource) ->
    {error, {unsupported_feature, datasource}}.

%% Generate an image through Hugging Face Inference Providers using fal-ai
%% and black-forest-labs/FLUX.1-dev.
-spec image(opensource | string() | binary(), large, string() | binary()) ->
    {ok, map()} | {error, term()}.
image(Provider, Size, Prompt) when is_list(Provider); is_binary(Provider) ->
    image(provider_atom(Provider), Size, Prompt);
image(opensource, large, Prompt) when is_list(Prompt); is_binary(Prompt) ->
    fal_image(Prompt).

cost(Provider, Model, Usage) ->
    llm_pricing:cost(Provider, Model, Usage).

cost(Provider, Model, Usage, Prices) ->
    llm_pricing:cost(Provider, Model, Usage, Prices).

default_model(anthropic, big)   -> ?ANTHROPIC_BIG;
default_model(anthropic, small) -> ?ANTHROPIC_SMALL;
default_model(anthropic, frontier) -> ?ANTHROPIC_FRONTIER;
default_model(openai, big)      -> ?OPENAI_BIG;
default_model(openai, small)    -> ?OPENAI_SMALL;
default_model(openai, frontier) -> ?OPENAI_FRONTIER;
default_model(opensource, big)  -> ?OPENSOURCE_BIG;
default_model(opensource, small)-> ?OPENSOURCE_SMALL;
default_model(opensource, frontier) -> ?OPENSOURCE_FRONTIER;
default_model(_Provider, Model) when is_list(Model); is_binary(Model) -> Model.

%% Public: returns the actual model id that chat/3..4 will hit for a given
%% Provider/Size pair (no Opts overrides, since the agent never sets any).
%% Useful for logging the real model name in training transcripts.
model_for(Provider, Size) ->
    default_model(provider_atom(Provider), Size).

%%--- Anthropic ------------------------------------------------------

anthropic_chat(Size, Messages, Tools, Opts, Strategy) ->
    ensure_started(),
    Key = require_env("ANTHROPIC_API_KEY"),
    Model = maps:get(model, Opts, default_model(anthropic, Size)),
    {System, Msgs} = extract_system(Messages),
    Body = anthropic_body(Model, System,
                          [anthropic_msg(M) || M <- Msgs],
                          [anthropic_tool(T) || T <- Tools],
                          Strategy, Opts),
    Headers = [{"x-api-key", Key},
               {"anthropic-version", ?ANTHROPIC_VER}],
    case post(?ANTHROPIC_URL, Headers, Body) of
        {ok, Resp} -> {ok, with_cost(anthropic, Model, Opts, parse_anthropic(Resp))};
        Err        -> Err
    end.

anthropic_body(Model, System, Msgs, Tools, Strategy, Opts) ->
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
    B3 = case cache_control(Strategy) of
             none -> B2;
             Control -> B2#{<<"cache_control">> => Control}
         end,
    B4 = case maps:get(reasoning_effort, Opts, undefined) of
             undefined -> B3;
             Eff -> B3#{<<"output_config">> => #{<<"effort">> => to_bin(Eff)}}
         end,
    json_util:encode(B4).

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
    Thinking = maps:get(thinking, M, []),
    case {Thinking, Calls} of
        {[], []} ->
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
              <<"content">> => Thinking ++ TextBlocks ++ ToolBlocks}
    end.

anthropic_tool(#{name := N, description := D, parameters := P}) ->
    #{<<"name">>         => to_bin(N),
      <<"description">>  => to_bin(D),
      <<"input_schema">> => P}.

parse_anthropic(Resp) ->
    Blocks = maps:get(<<"content">>, Resp, []),
    {Text, Calls, Thinking} = lists:foldl(fun fold_anthropic_block/2,
                                           {<<>>, [], []}, Blocks),
    Usage = parse_anthropic_usage(Resp),
    Base = #{role => assistant, content => Text, tool_calls => Calls, usage => Usage},
    put_thinking(Base, Thinking).

fold_anthropic_block(Block, {TAcc, CAcc, ThinkAcc}) ->
    case maps:get(<<"type">>, Block, undefined) of
        <<"text">> ->
            {<<TAcc/binary, (maps:get(<<"text">>, Block, <<>>))/binary>>,
             CAcc, ThinkAcc};
        <<"tool_use">> ->
            Call = #{id    => maps:get(<<"id">>, Block),
                     name  => maps:get(<<"name">>, Block),
                     input => maps:get(<<"input">>, Block, #{})},
            {TAcc, CAcc ++ [Call], ThinkAcc};
        Type when Type =:= <<"thinking">>; Type =:= <<"redacted_thinking">> ->
            {TAcc, CAcc, ThinkAcc ++ [Block]};
        _ ->
            {TAcc, CAcc, ThinkAcc}
    end.

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
        {ok, Resp} -> {ok, with_cost(openai, Model, Opts1, parse_openai_response(Resp))};
        Err        -> Err
    end.

openai_responses_body(Model, InputItems, Tools, Datasource, Opts) ->
    Base0 = #{<<"model">> => to_bin(Model),
              <<"input">> => InputItems,
              <<"max_output_tokens">> => ?MAX_TOKENS,
              <<"include">> => [<<"reasoning.encrypted_content">>]},
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
    Thinking = [reasoning_input_item(B) || B <- maps:get(thinking, M, [])],
    Msgs = case Text of
               <<>> -> [];
               T    -> [assistant_text_input_item(T)]
           end,
    Thinking ++ Msgs ++ [function_call_input_item(TC) || TC <- Calls];
message_to_responses_input(#{role := tool_result, tool_use_id := Id, content := C}) ->
    [#{<<"type">>   => <<"function_call_output">>,
       <<"call_id">> => to_bin(Id),
       <<"output">>  => to_bin(C)}].

easy_input_message(Role, Content) when is_binary(Content); is_list(Content) ->
    #{<<"role">> => Role, <<"content">> => to_bin(Content)}.

assistant_text_input_item(Text) ->
    #{<<"role">> => <<"assistant">>,
      <<"content">> => [#{<<"type">> => <<"input_text">>, <<"text">> => to_bin(Text)}]}.

reasoning_input_item(Block) ->
    Kept = maps:with([<<"id">>, <<"summary">>, <<"content">>, <<"encrypted_content">>], Block),
    Item = Kept#{<<"type">> => <<"reasoning">>},
    case maps:is_key(<<"summary">>, Item) of
        true -> Item;
        false -> Item#{<<"summary">> => []}
    end.

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
    {Text, Calls, Thinking} = lists:foldl(fun fold_output_item/2, {<<>>, [], []}, Out),
    Usage = parse_openai_responses_usage(Resp),
    put_thinking(#{role => assistant, content => Text, tool_calls => Calls,
                   usage => Usage}, Thinking).

fold_output_item(Item, {TAcc, CAcc, ThinkAcc}) ->
    case maps:get(<<"type">>, Item, undefined) of
        <<"message">> ->
            T = extract_assistant_output_text(Item),
            {<<TAcc/binary, T/binary>>, CAcc, ThinkAcc};
        <<"function_call">> ->
            CallId = maps:get(<<"call_id">>, Item),
            Name = maps:get(<<"name">>, Item),
            ArgsBin = maps:get(<<"arguments">>, Item, <<"{}">>),
            Input = json_util:decode(ArgsBin),
            Call = #{id => CallId, name => Name, input => Input},
            {TAcc, CAcc ++ [Call], ThinkAcc};
        <<"reasoning">> ->
            {TAcc, CAcc, ThinkAcc ++ [Item]};
        _ ->
            {TAcc, CAcc, ThinkAcc}
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
        null -> #{in => 0, out => 0, cache_read => 0, cache_write => 0,
                  reasoning => 0};
        U    ->
            Details = maps:get(<<"output_tokens_details">>, U, #{}),
            Thinking = case Details of
                           Map when is_map(Map) ->
                               maps:get(<<"thinking_tokens">>, Map, 0);
                           _ ->
                               0
                       end,
            Creation = maps:get(<<"cache_creation">>, U, #{}),
            Write1h = case Creation of
                          C when is_map(C) ->
                              maps:get(<<"ephemeral_1h_input_tokens">>, C, 0);
                          _ ->
                              0
                      end,
            #{in         => maps:get(<<"input_tokens">>, U, 0),
              out        => maps:get(<<"output_tokens">>, U, 0),
              cache_read => maps:get(<<"cache_read_input_tokens">>, U, 0),
              cache_write => maps:get(<<"cache_creation_input_tokens">>, U, 0),
              cache_write_1h => Write1h,
              reasoning  => Thinking}
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

%%--- OpenRouter (OpenAI-compatible Chat Completions) ----------------

openrouter_chat(Size, Messages, Tools, Opts) ->
    ensure_started(),
    Key = require_env("OPENROUTER_API_KEY"),
    Model = maps:get(model, Opts, default_model(opensource, Size)),
    Body = openrouter_body(Model, Messages, Tools, Opts),
    Headers = [{"authorization", "Bearer " ++ Key}],
    case post(?OPENROUTER_CHAT_URL, Headers, Body) of
        {ok, Resp} ->
            case parse_openrouter_response(Resp) of
                {ok, Parsed} -> {ok, with_cost(opensource, Model, Opts, Parsed)};
                Err -> Err
            end;
        Err ->
            Err
    end.

openrouter_body(Model, Messages, Tools, Opts) ->
    Base = #{<<"model">> => to_bin(Model),
             <<"messages">> => [openrouter_message(M) || M <- Messages],
             <<"max_tokens">> => ?MAX_TOKENS},
    B1 = case Tools of
             [] -> Base;
             _  -> Base#{<<"tools">> => [openrouter_tool(T) || T <- Tools],
                         <<"tool_choice">> => <<"auto">>}
         end,
    B2 = case maps:get(reasoning_effort, Opts, undefined) of
             undefined -> B1;
             Eff ->
                 B1#{<<"reasoning">> => #{<<"effort">> => to_bin(Eff)}}
         end,
    json_util:encode(B2).

openrouter_message(#{role := tool_result, tool_use_id := Id, content := C}) ->
    #{<<"role">> => <<"tool">>,
      <<"tool_call_id">> => to_bin(Id),
      <<"content">> => to_bin(C)};
openrouter_message(#{role := user, parts := Parts}) ->
    #{<<"role">> => <<"user">>,
      <<"content">> => [openrouter_user_part(P) || P <- Parts]};
openrouter_message(#{role := assistant} = M) ->
    Text = maps:get(content, M, <<>>),
    Calls = maps:get(tool_calls, M, []),
    Base = #{<<"role">> => <<"assistant">>, <<"content">> => to_bin(Text)},
    Base1 = case Calls of
                [] -> Base;
                _  -> Base#{<<"tool_calls">> => [openrouter_tool_call(TC) || TC <- Calls]}
            end,
    case openrouter_thinking_replay(maps:get(thinking, M, [])) of
        none -> Base1;
        {reasoning, Reasoning} -> Base1#{<<"reasoning">> => Reasoning};
        {details, Blocks} -> Base1#{<<"reasoning_details">> => Blocks}
    end;
openrouter_message(#{role := Role, content := Content}) ->
    #{<<"role">> => atom_to_binary(Role), <<"content">> => to_bin(Content)}.

openrouter_user_part({text, T}) ->
    #{<<"type">> => <<"text">>, <<"text">> => to_bin(T)};
openrouter_user_part({image_base64, Mime, B64}) ->
    Url = iolist_to_binary(["data:", to_bin(Mime), ";base64,", B64]),
    #{<<"type">> => <<"image_url">>,
      <<"image_url">> => #{<<"url">> => Url}}.

openrouter_tool(#{name := N, description := D, parameters := P}) ->
    #{<<"type">> => <<"function">>,
      <<"function">> => #{<<"name">> => to_bin(N),
                           <<"description">> => to_bin(D),
                           <<"parameters">> => P}}.

openrouter_tool_call(#{id := Id, name := Name, input := Input}) ->
    #{<<"id">> => to_bin(Id),
      <<"type">> => <<"function">>,
      <<"function">> => #{<<"name">> => to_bin(Name),
                           <<"arguments">> => json_util:encode(Input)}}.

parse_openrouter_response(#{<<"error">> := Error}) ->
    {error, {openrouter, Error}};
parse_openrouter_response(Resp) ->
    case maps:get(<<"choices">>, Resp, undefined) of
        [Choice | _] ->
            Message = maps:get(<<"message">>, Choice, #{}),
            Text = case maps:get(<<"content">>, Message, null) of
                       null -> <<>>;
                       C    -> C
                   end,
            Calls = [parse_openrouter_tool_call(TC)
                     || TC <- as_list(maps:get(<<"tool_calls">>, Message, []))],
            {ok, put_thinking(#{role => assistant,
                                content => Text,
                                tool_calls => Calls,
                                usage => parse_openrouter_usage(Resp)},
                              openrouter_thinking(Message))};
        [] ->
            {error, {openrouter, empty_choices}};
        undefined ->
            {error, {openrouter, {missing_choices, Resp}}}
    end.

parse_openrouter_tool_call(TC) ->
    Function = maps:get(<<"function">>, TC),
    Arguments = maps:get(<<"arguments">>, Function, <<"{}">>),
    #{id => maps:get(<<"id">>, TC),
      name => maps:get(<<"name">>, Function),
      input => json_util:decode(Arguments)}.

openrouter_thinking(Message) ->
    case maps:get(<<"reasoning_details">>, Message, undefined) of
        [_ | _] = Details ->
            Details;
        _ ->
            case reasoning_text(Message) of
                <<>> -> [];
                Text -> [#{<<"type">> => <<"reasoning">>, <<"text">> => Text}]
            end
    end.

reasoning_text(Message) ->
    case maps:get(<<"reasoning">>, Message, maps:get(<<"reasoning_content">>, Message, <<>>)) of
        null -> <<>>;
        Text when is_binary(Text) -> Text;
        Text when is_list(Text) -> to_bin(Text);
        _ -> <<>>
    end.

openrouter_thinking_replay([]) ->
    none;
openrouter_thinking_replay(Blocks) ->
    case lists:all(fun plain_reasoning_text/1, Blocks) of
        true ->
            Text = lists:foldl(fun(B, Acc) ->
                                   <<Acc/binary, (maps:get(<<"text">>, B, <<>>))/binary>>
                               end, <<>>, Blocks),
            {reasoning, Text};
        false ->
            {details, Blocks}
    end.

%% A plain string from the API is stored as one block. Real reasoning_details
%% use types such as reasoning.text and must be sent back as they arrived.
plain_reasoning_text(#{<<"type">> := <<"reasoning">>, <<"text">> := Text} = Block)
  when is_binary(Text) ->
    maps:size(Block) =:= 2;
plain_reasoning_text(_) ->
    false.

put_thinking(Resp, []) ->
    Resp;
put_thinking(Resp, Thinking) ->
    Resp#{thinking => Thinking}.

as_list(L) when is_list(L) -> L;
as_list(_) -> [].

usage_details(Map) when is_map(Map) -> Map;
usage_details(_) -> #{}.

parse_openrouter_usage(Resp) ->
    case maps:get(<<"usage">>, Resp, null) of
        null -> #{in => 0, out => 0, cache_read => 0, reasoning => 0};
        U ->
            PromptDetails = usage_details(maps:get(<<"prompt_tokens_details">>, U, #{})),
            CompletionDetails = usage_details(maps:get(<<"completion_tokens_details">>, U, #{})),
            Usage = #{in => maps:get(<<"prompt_tokens">>, U, 0),
                      out => maps:get(<<"completion_tokens">>, U, 0),
                      cache_read => maps:get(<<"cached_tokens">>, PromptDetails, 0),
                      reasoning => maps:get(<<"reasoning_tokens">>, CompletionDetails, 0)},
            case maps:get(<<"cost">>, U, undefined) of
                Cost when is_number(Cost) -> Usage#{provider_cost => Cost};
                _ -> Usage
            end
    end.

with_cost(Provider, Model, Opts, #{usage := Usage} = Resp) ->
    Resp#{usage => price_usage(Provider, Model, Usage, Opts)}.

price_usage(Provider, Model, Usage, Opts) ->
    Public = maps:remove(provider_cost, Usage),
    case maps:get(pricing, Opts, true) of
        false ->
            Public;
        _ ->
            Prices = maps:get(prices, Opts, llm_prices:list()),
            case llm_pricing:cost(Provider, Model, Usage, Prices) of
                {ok, Cost} -> Public#{cost_usd => Cost};
                {error, _} -> Public
            end
    end.

%%--- Hugging Face / fal-ai image generation ------------------------

fal_image(Prompt) ->
    ensure_started(),
    Key = require_env("HF_TOKEN"),
    Body = json_util:encode(#{<<"prompt">> => to_bin(Prompt)}),
    Headers = [{"authorization", "Bearer " ++ Key}],
    case post(?HUGGINGFACE_FAL_FLUX_DEV_URL, Headers, Body) of
        {ok, Resp} -> parse_fal_image_response(Resp, Headers);
        Err        -> Err
    end.

%% Hugging Face's fal-ai router often accepts the job and returns
%% request_id / status_url immediately. Poll until COMPLETED, then
%% download images[0].url. A completed payload is handled the same way.
parse_fal_image_response(#{<<"error">> := Error}, _Headers) ->
    {error, {huggingface, Error}};
parse_fal_image_response(
  #{<<"images">> := [#{<<"url">> := Url} = Image | _]}, _Headers) ->
    fetch_fal_image(Url, Image);
parse_fal_image_response(#{<<"images">> := [Image | _]}, _Headers) ->
    {error, {huggingface, {missing_image_url, Image}}};
parse_fal_image_response(#{<<"request_id">> := _} = Queue, Headers) ->
    await_fal_queue(Queue, Headers);
parse_fal_image_response(Resp, _Headers) ->
    {error, {huggingface, {missing_images, Resp}}}.

fetch_fal_image(<<"data:", Rest/binary>>, Image) ->
    case binary:split(Rest, <<",">>) of
        [_Meta, B64] ->
            ContentType = maps:get(<<"content_type">>, Image, <<"image/jpeg">>),
            {ok, #{image => base64:decode(B64),
                   content_type => to_bin(ContentType)}};
        _ ->
            {error, {huggingface, {invalid_data_url, Image}}}
    end;
fetch_fal_image(Url, Image) ->
    ContentType = maps:get(<<"content_type">>, Image,
                           <<"application/octet-stream">>),
    case get_binary(Url) of
        {ok, ImageBin} ->
            {ok, #{image => ImageBin,
                   content_type => to_bin(ContentType)}};
        Err ->
            Err
    end.

await_fal_queue(Queue, Headers) ->
    {StatusUrl, ResultUrl} = fal_queue_urls(Queue),
    Deadline = erlang:monotonic_time(millisecond) + ?TIMEOUT_MS,
    case poll_fal_queue(Headers, StatusUrl, ResultUrl, Deadline) of
        {ok, Result} -> parse_fal_queue_result(Result);
        Err -> Err
    end.

parse_fal_queue_result(#{<<"error">> := Error}) ->
    {error, {huggingface, Error}};
parse_fal_queue_result(
  #{<<"images">> := [#{<<"url">> := Url} = Image | _]}) ->
    fetch_fal_image(Url, Image);
parse_fal_queue_result(#{<<"images">> := [Image | _]}) ->
    {error, {huggingface, {missing_image_url, Image}}};
parse_fal_queue_result(Resp) ->
    {error, {huggingface, {missing_images, Resp}}}.

fal_queue_urls(#{<<"request_id">> := RequestId} = Queue) ->
    DefaultStatus = iolist_to_binary(
        [?HUGGINGFACE_FAL_FLUX_DEV_URL, "/requests/", RequestId, "/status"]),
    DefaultResult = iolist_to_binary(
        [?HUGGINGFACE_FAL_FLUX_DEV_URL, "/requests/", RequestId, "/response"]),
    {rewrite_hf_fal_url(maps:get(<<"status_url">>, Queue, DefaultStatus)),
     rewrite_hf_fal_url(maps:get(<<"response_url">>, Queue, DefaultResult))}.

%% HF tokens cannot call queue.fal.run directly; rewrite onto the HF router.
rewrite_hf_fal_url(Url) ->
    case uri_string:parse(to_bin(Url)) of
        #{host := Host} = Parsed when is_map(Parsed) ->
            Path = to_bin(maps:get(path, Parsed, <<>>)),
            Query = case maps:get(query, Parsed, undefined) of
                        undefined -> <<>>;
                        Q -> <<$?, (to_bin(Q))/binary>>
                    end,
            case to_bin(Host) of
                <<"queue.fal.run">> ->
                    binary_to_list(<<"https://router.huggingface.co/fal-ai",
                                     Path/binary, Query/binary>>);
                <<"fal.run">> ->
                    binary_to_list(<<"https://router.huggingface.co/fal-ai",
                                     Path/binary, Query/binary>>);
                _ ->
                    binary_to_list(to_bin(Url))
            end;
        _ ->
            binary_to_list(to_bin(Url))
    end.

poll_fal_queue(Headers, StatusUrl, ResultUrl, Deadline) ->
    case erlang:monotonic_time(millisecond) > Deadline of
        true ->
            {error, {huggingface, queue_timeout}};
        false ->
            case get_json(StatusUrl, Headers) of
                {ok, #{<<"status">> := <<"COMPLETED">>}} ->
                    get_json(ResultUrl, Headers);
                {ok, #{<<"status">> := <<"FAILED">>} = Status} ->
                    {error, {huggingface, {queue_failed, Status}}};
                {ok, #{<<"status">> := Status}}
                  when Status =:= <<"IN_QUEUE">>;
                       Status =:= <<"IN_PROGRESS">> ->
                    timer:sleep(?FAL_POLL_MS),
                    poll_fal_queue(Headers, StatusUrl, ResultUrl, Deadline);
                {ok, Other} ->
                    {error, {huggingface, {unexpected_queue_status, Other}}};
                Err ->
                    Err
            end
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

get_binary(Url) ->
    get_request(Url, [], fun(RespBody) -> {ok, RespBody} end).

get_json(Url, Headers) ->
    get_request(Url, Headers, fun(RespBody) -> {ok, json_util:decode(RespBody)} end).

get_request(Url, Headers, Decode) ->
    case httpc:request(get,
            {to_url_string(Url), Headers},
            [{ssl, [{verify, verify_none}]}, {timeout, ?TIMEOUT_MS},
             {autoredirect, true}],
            [{body_format, binary}]) of
        {ok, {{_, S, _}, _, RespBody}} when S >= 200, S < 300 ->
            Decode(RespBody);
        {ok, {{_, S, _}, _, RespBody}} ->
            {error, {http, S, RespBody}};
        {error, Reason} ->
            {error, Reason}
    end.

to_url_string(Url) when is_list(Url) -> Url;
to_url_string(Url) -> binary_to_list(to_bin(Url)).

anthropic_user_part({text, T}) ->
    #{<<"type">> => <<"text">>, <<"text">> => to_bin(T)};
anthropic_user_part({image_base64, Mime, B64}) ->
    #{<<"type">> => <<"image">>, <<"source">> => #{
        <<"type">> => <<"base64">>,
        <<"media_type">> => to_bin(Mime),
        <<"data">> => B64
    }}.

%%--- Helpers --------------------------------------------------------

provider_atom(openai) -> openai;
provider_atom(anthropic) -> anthropic;
provider_atom(opensource) -> opensource;
provider_atom("openai") -> openai;
provider_atom("anthropic") -> anthropic;
provider_atom("opensource") -> opensource;
provider_atom(<<"openai">>) -> openai;
provider_atom(<<"anthropic">>) -> anthropic;
provider_atom(<<"opensource">>) -> opensource.

require_env(Name) ->
    case os:getenv(Name) of
        false -> error({missing_env, Name});
        Val   -> Val
    end.

with_caching(Opts, Fun) ->
    case caching_strategy(maps:get(caching, Opts, five_minutes)) of
        {ok, Strategy} -> Fun(Strategy);
        error -> {error, {invalid_option, caching}}
    end.

%% five_minutes is the Anthropic default: cache_control ephemeral, ttl 5m.
%% one_hour uses ttl 1h. off omits cache_control.
caching_strategy(five_minutes) -> {ok, five_minutes};
caching_strategy(one_hour) -> {ok, one_hour};
caching_strategy(off) -> {ok, off};
caching_strategy(false) -> {ok, off};
caching_strategy(none) -> {ok, off};
caching_strategy("five_minutes") -> {ok, five_minutes};
caching_strategy("one_hour") -> {ok, one_hour};
caching_strategy("off") -> {ok, off};
caching_strategy("none") -> {ok, off};
caching_strategy(<<"five_minutes">>) -> {ok, five_minutes};
caching_strategy(<<"one_hour">>) -> {ok, one_hour};
caching_strategy(<<"off">>) -> {ok, off};
caching_strategy(<<"none">>) -> {ok, off};
caching_strategy(_) -> error.

cache_control(five_minutes) ->
    #{<<"type">> => <<"ephemeral">>, <<"ttl">> => <<"5m">>};
cache_control(one_hour) ->
    #{<<"type">> => <<"ephemeral">>, <<"ttl">> => <<"1h">>};
cache_control(off) ->
    none.

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L)   -> unicode:characters_to_binary(L);
to_bin(A) when is_atom(A)   -> atom_to_binary(A).
