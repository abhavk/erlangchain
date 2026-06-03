# erlangchain

Minimal building blocks for talking to LLMs from Erlang, with zero third-party
dependencies (only OTP `inets` + `ssl`).

| Module      | Role                                                          |
|-------------|---------------------------------------------------------------|
| `llm`       | one-call chat client for OpenAI (Responses API) and Anthropic, with tool-use and multimodal support |
| `json_util` | dependency-free JSON encode/decode                            |

## Install

```erlang
%% rebar.config
{deps, [
    {erlangchain, {git, "https://github.com/you/erlangchain.git", {tag, "0.1.0"}}}
]}.
```

Set `OPENAI_API_KEY` and/or `ANTHROPIC_API_KEY` in the environment (a `.env`
file in the working directory is loaded automatically if present).

## llm

```erlang
%% Simple completion (defaults to openai/small):
{ok, #{content := Text}} = llm:chat([#{role => user, content => <<"hello">>}]),

%% Pick provider + size:
{ok, Resp} = llm:chat(openai, big, Messages),

%% Tool use — pass tool specs, get back tool_calls to run and feed back:
{ok, #{tool_calls := Calls}} = llm:chat(openai, big, Messages, Tools).
```

`Messages` are maps like `#{role => system|user|assistant, content => binary()}`,
plus `#{role => tool_result, tool_use_id => Id, content => Bin}` to return tool
output. See the header of `src/llm.erl` for the full message/response shapes.

## json_util

```erlang
<<"{\"a\":1}">> = json_util:encode(#{<<"a">> => 1}),
#{<<"a">> := 1} = json_util:decode(<<"{\"a\":1}">>).
```

## License

MIT — see [LICENSE](LICENSE).
