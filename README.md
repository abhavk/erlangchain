# erlangchain

[![DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/abhavk/erlangchain)

Minimal building blocks for talking to LLMs from Erlang, without third-party
dependencies.

| Module      | Role                                                          |
|-------------|---------------------------------------------------------------|
| `llm`       | one-call chat client for OpenAI (Responses API) and Anthropic, with tool-use and multimodal support |
| `llm_datasource` | create and manage provider-backed vector-store datasources |
| `json_util` | dependency-free JSON encode/decode                            |

## Install

```erlang
%% rebar.config
{deps, [
    {erlangchain, "~> 0.2.0"}
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
output. `Datasource` is `none` or an OpenAI vector store id. Anthropic does not
support managed vector-store datasources. See the header of `src/llm.erl` for the
full message/response shapes. Deleting datasource files detaches them from that
vector store; it does not permanently delete the uploaded OpenAI files.

## json_util

```erlang
<<"{\"a\":1}">> = json_util:encode(#{<<"a">> => 1}),
#{<<"a">> := 1} = json_util:decode(<<"{\"a\":1}">>).
```

## License

MIT — see [LICENSE](LICENSE).
