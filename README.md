# erlangchain

[![DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/abhavk/erlangchain)

Erlangchain is a small Erlang library that talks to AI services for you. Your
app calls a few functions. The library handles the HTTP requests, the JSON, and
the differences between providers. It has no third-party dependencies.

It gives you three things:

1. **Chat.** `llm:chat/1` through `llm:chat/6` send a conversation to OpenAI,
   Anthropic, or OpenRouter (`opensource`). You pick a size (`small`, `big`, or
   `frontier`) or name an exact model. You get back text, tool calls, and token
   usage in one map. You can also send a picture in a user message so the model
   can look at it.
2. **Image generation.** `llm:image(opensource, large, Prompt)` asks Hugging
   Face (fal-ai, FLUX.1-dev) to make a picture. You get the image bytes and a
   MIME type. The library waits out the queue so your code does not have to.
3. **OpenAI file search.** `llm_datasource` creates a vector store, adds or
   removes files, and deletes it. Pass that store id into `llm:chat` so OpenAI
   can search those files.

`json_util` is a helper for encoding and decoding JSON.

The point is one Erlang API instead of writing a separate client for each
vendor.

| Module      | Role                                                          |
|-------------|---------------------------------------------------------------|
| `llm`       | chat and image-generation client for OpenAI, Anthropic, OpenRouter, and Hugging Face Inference Providers |
| `llm_datasource` | create and manage provider-backed vector-store datasources |
| `json_util` | dependency-free JSON encode/decode                            |

## Install

```erlang
%% rebar.config
{deps, [
    {erlangchain, "~> 4.2.0"}
]}.
```

Set `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `OPENROUTER_API_KEY`, and/or
`HF_TOKEN` in the environment (a `.env` file in the working directory is loaded
automatically if present).

**4.2.0** adds token pricing, the `claude-opus-5-5` rate, and Anthropic
thinking blocks. Chat calls keep the same arguments and the same fields.
`cost_usd` is added when a price is known. A model with no price still returns
`{ok, Response}`. An Anthropic reply includes `thinking` only when the API
sent thinking blocks, and those blocks are sent back on the next turn.

## llm

```erlang
%% Simple completion (defaults to openai/small):
{ok, #{content := Text}} = llm:chat([#{role => user, content => <<"hello">>}]),

%% Pick provider + size:
{ok, Resp} = llm:chat(openai, big, Messages),

%% Open-source models through OpenRouter:
{ok, Resp} = llm:chat(opensource, small, Messages),

%% Image generation through Hugging Face's fal-ai provider:
{ok, #{image := ImageBytes, content_type := MimeType}} =
    llm:image(opensource, large, <<"Astronaut riding a horse">>),

%% Frontier tier, or an exact model slug:
{ok, Resp} = llm:chat(openai, frontier, Messages),
{ok, Resp} = llm:chat("openai", "exact-model-slug", Messages),

%% Tool use — pass tool specs, get back tool_calls to run and feed back:
{ok, #{tool_calls := Calls}} = llm:chat(openai, big, Messages, Tools),

%% OpenAI file search — pass a vector store id before Opts:
{ok, Resp} = llm:chat(openai, big, Messages, Tools, <<"vs_product_docs">>, #{}).

%% Datasource lifecycle — file paths are uploaded and attached as one batch:
{ok, DatasourceId} = llm_datasource:create(openai, <<"Product docs">>),
{ok, #{file_ids := FileIds}} =
    llm_datasource:files_add(
        openai, DatasourceId, ["docs/guide.pdf", "docs/api.md"]
    ),
ok = llm_datasource:files_remove(openai, DatasourceId, FileIds),
ok = llm_datasource:delete(openai, DatasourceId).
```

`Messages` are maps like `#{role => system|user|assistant, content => binary()}`,
plus `#{role => tool_result, tool_use_id => Id, content => Bin}` to return tool
output. The `frontier` models are `gpt-5.6-sol` for OpenAI, `fable-5` for
Anthropic, and `moonshotai/kimi-k3` for the `opensource` OpenRouter provider.
The other `opensource` defaults are `openai/gpt-oss-20b` for `small` and
`z-ai/glm-5.2` for `big`. A tier can be replaced with an exact model slug as a
string or binary; provider names also accept atoms, strings, or binaries.
Alternatively, pass `#{model => "provider/model"}` in `Opts`. `Datasource` is
`none` or an OpenAI vector store id. Other providers do not support managed
vector-store datasources. See the header of `src/llm.erl` for the full
message/response shapes. Deleting datasource files detaches them from that
vector store; it does not permanently delete the uploaded OpenAI files.

## Token cost

Chat adds `cost_usd` to `usage` when the model is in the built-in price list.
OpenRouter's own `usage.cost` is used for `opensource` when the response
includes it.

```erlang
{ok, #{usage := #{cost_usd := Dollars}}} =
    llm:chat(openai, small, Messages),

{ok, Dollars} = llm:cost(openai, <<"gpt-5.6-luna">>, Usage).
```

`#{pricing => false}` in `Opts` leaves the cost off. `#{prices => PriceList}`
uses your rates instead of `llm_prices:list/0`. Rates are USD per 1,000,000
tokens: `#{<<"model">> => #{in => 0.20, out => 1.20, cache_read => 0.02}}`.
The rules live in `llm_pricing`. `cost_usd` is token cost only.

## Image generation

`llm:image/3` is separate from `llm:chat/3`. Only this call is supported:

```erlang
llm:image(opensource, large, Prompt) ->
    {ok, #{image := ImageBytes, content_type := MimeType}} | {error, Reason}.
```

`Prompt` is a string or binary. `image` is the encoded file bytes (JPEG or
PNG, not a URL). `content_type` is the MIME type, such as `<<"image/jpeg">>`.

This uses `black-forest-labs/FLUX.1-dev` through Hugging Face's `fal-ai`
provider and requires `HF_TOKEN`. Hugging Face often answers immediately with
a `request_id` instead of an image. Since 0.4.1 the client treats that as a
queued job: it polls until the job finishes or fails, downloads the image,
and only then returns `{ok, ...}`. The caller does not see the queue.

Other providers and sizes do not implement `llm:image/3`.

## json_util

```erlang
<<"{\"a\":1}">> = json_util:encode(#{<<"a">> => 1}),
#{<<"a">> := 1} = json_util:decode(<<"{\"a\":1}">>).
```

## License

MIT — see [LICENSE](LICENSE).
