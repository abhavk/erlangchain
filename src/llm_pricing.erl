-module(llm_pricing).
-export([cost/3, cost/4]).

%% Turn a usage map into USD.
%%
%%   cost(Provider, Model, Usage) -> {ok, CostUsd} | {error, unknown_model}
%%   cost(Provider, Model, Usage, Prices) -> same
%%
%% Usage = #{in => number(), out => number(), cache_read => number(),
%%           reasoning => number(), provider_cost => number()}
%% Prices = #{Model => #{in => Rate, out => Rate, cache_read => Rate,
%%                       long => #{after_tokens => N, in => Rate, out => Rate,
%%                                 cache_read => Rate}}}
%% Rates are USD per 1,000,000 tokens.
%%
%% openai and opensource: cache_read is already inside in, and reasoning is
%% already inside out. Bill (in - cache_read) at the input rate, cache_read
%% at the cache rate, and out at the output rate.
%% anthropic: in, cache_read, cache_write, and out are separate buckets.
%%            cache_write_1h is the part of cache_write stored for 1 hour
%%            (2x input). The rest is a 5-minute write (1.25x input).
%% opensource: a provider_cost from OpenRouter replaces the price list,
%% because the live route is the real bill.

cost(Provider, Model, Usage) ->
    cost(Provider, Model, Usage, llm_prices:list()).

cost(Provider, Model, Usage, Prices)
  when is_map(Usage), is_map(Prices) ->
    case provider(Provider) of
        opensource ->
            case maps:get(provider_cost, Usage, undefined) of
                Cost when is_number(Cost) ->
                    {ok, float(Cost)};
                _ ->
                    from_list(opensource, Model, Usage, Prices)
            end;
        Known when Known =:= openai; Known =:= anthropic ->
            from_list(Known, Model, Usage, Prices);
        _ ->
            {error, unknown_model}
    end.

from_list(Provider, Model, Usage, Prices) ->
    case lookup(Model, Prices) of
        {ok, Rates} ->
            case priced(Provider, Usage, Rates) of
                {ok, Cost} -> {ok, Cost};
                error -> {error, unknown_model}
            end;
        error ->
            {error, unknown_model}
    end.

priced(Provider, Usage, Rates) ->
    case rates_for(Usage, Rates) of
        error ->
            error;
        Use ->
            In = num(in, Usage),
            Out = num(out, Usage),
            Cache = num(cache_read, Usage),
            Cost = case Provider of
                       anthropic ->
                           tokens(In, in, Use) +
                           tokens(Cache, cache_read, Use) +
                           cache_write_cost(Usage, Use) +
                           tokens(Out, out, Use);
                       _ ->
                           tokens(max(0, In - Cache), in, Use) +
                           tokens(Cache, cache_read, Use) +
                           tokens(Out, out, Use)
                   end,
            {ok, Cost}
    end.

rates_for(Usage, Rates) ->
    case {maps:find(in, Rates), maps:find(out, Rates)} of
        {{ok, _}, {ok, _}} ->
            In = num(in, Usage),
            case maps:get(long, Rates, undefined) of
                #{after_tokens := N} = Long when is_number(N), In > N ->
                    maps:merge(Rates, maps:remove(after_tokens, Long));
                _ ->
                    Rates
            end;
        _ ->
            error
    end.

tokens(Count, cache_read, Rates) ->
    Count / 1000000 * maps:get(cache_read, Rates, maps:get(in, Rates));
tokens(Count, Key, Rates) ->
    Count / 1000000 * maps:get(Key, Rates).

cache_write_cost(Usage, Rates) ->
    Write = num(cache_write, Usage),
    Write1h = min(Write, num(cache_write_1h, Usage)),
    Write5m = max(0, Write - Write1h),
    In = maps:get(in, Rates),
    FiveRate = maps:get(cache_write, Rates, In * 1.25),
    HourRate = maps:get(cache_write_1h, Rates, In * 2.0),
    Write5m / 1000000 * FiveRate + Write1h / 1000000 * HourRate.

lookup(Model, Prices) ->
    Key = to_bin(Model),
    case maps:find(Key, Prices) of
        {ok, Rates} when is_map(Rates) -> {ok, Rates};
        _ ->
            case maps:find(binary_to_list(Key), Prices) of
                {ok, Rates} when is_map(Rates) -> {ok, Rates};
                _ -> error
            end
    end.

num(Key, Usage) ->
    case maps:get(Key, Usage, 0) of
        N when is_number(N) -> N;
        _ -> 0
    end.

provider(openai) -> openai;
provider(anthropic) -> anthropic;
provider(opensource) -> opensource;
provider("openai") -> openai;
provider("anthropic") -> anthropic;
provider("opensource") -> opensource;
provider(<<"openai">>) -> openai;
provider(<<"anthropic">>) -> anthropic;
provider(<<"opensource">>) -> opensource;
provider(_) -> unknown.

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> unicode:characters_to_binary(L);
to_bin(A) when is_atom(A) -> atom_to_binary(A).
