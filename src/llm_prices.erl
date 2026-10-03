-module(llm_prices).
-export([list/0]).

%% USD per 1,000,000 tokens for the models llm.erl calls by default.
%% Rates are public list prices as of 2026-10-02.
%%
%%   in         uncached input
%%   out        output, including reasoning tokens where the provider
%%              already counts those inside output
%%   cache_read cached input, when the vendor publishes a separate rate
%%
%% A missing cache_read rate means those tokens are billed as normal input.
%% Long-context surcharges, cache writes, and tool-call fees are not in
%% this list. OpenRouter routes one model across many hosts, so the
%% opensource entries are the lowest posted host rate, not a guaranteed bill.
%% When OpenRouter returns usage.cost, that number is used instead.

list() ->
    #{<<"gpt-5.6-luna">> =>
          #{in => 0.20, out => 1.20, cache_read => 0.02,
            long => #{after_tokens => 272000,
                      in => 0.40, out => 1.80, cache_read => 0.04}},
      <<"gpt-5.6-terra">> =>
          #{in => 2.00, out => 12.00, cache_read => 0.20},
      <<"gpt-5.6-sol">> =>
          #{in => 4.00, out => 20.00, cache_read => 0.40},
      <<"claude-haiku-3-5-20241022">> =>
          #{in => 0.80, out => 4.00, cache_read => 0.08},
      <<"claude-sonnet-4-20250514">> =>
          #{in => 3.00, out => 15.00, cache_read => 0.30},
      <<"fable-5">> =>
          #{in => 10.00, out => 50.00, cache_read => 1.00},
      <<"claude-opus-5-5">> =>
          #{in => 4.00, out => 20.00, cache_read => 0.20},
      <<"openai/gpt-oss-20b">> =>
          #{in => 0.018, out => 0.09},
      <<"z-ai/glm-5.2">> =>
          #{in => 0.20, out => 4.00, cache_read => 0.20},
      <<"moonshotai/kimi-k3">> =>
          #{in => 0.19, out => 11.00, cache_read => 0.18}}.
