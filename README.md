# erlangchain

[![DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/abhavk/erlangchain)

Minimal building blocks for talking to LLMs from Erlang, without third-party
dependencies.

| Module      | Role                                                          |
|-------------|---------------------------------------------------------------|
| `llm`       | chat and image-generation client for OpenAI, Anthropic, OpenRouter, and Hugging Face Inference Providers |
| `llm_datasource` | create and manage provider-backed vector-store datasources |
| `json_util` | dependency-free JSON encode/decode                            |

## Install

```erlang
%% rebar.config
{deps, [
    {erlangchain, "~> 0.2.0"}
]}.
```

Set `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `OPENROUTER_API_KEY`, and/or
`HF_TOKEN` in the environment (a `.env` file in the working directory is loaded
automatically if present).

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

`llm:image(opensource, large, Prompt)` uses
`black-forest-labs/FLUX.1-dev` through Hugging Face's `fal-ai` provider. It
requires `HF_TOKEN` and returns the encoded image bytes and their MIME type.

## json_util

```erlang
<<"{\"a\":1}">> = json_util:encode(#{<<"a">> => 1}),
#{<<"a">> := 1} = json_util:decode(<<"{\"a\":1}">>).
```

## License

MIT — see [LICENSE](LICENSE).
