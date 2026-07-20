-module(llm_datasource).
-export([create/2, delete/2, files_add/3, files_remove/3]).
-export_type([id/0, file_id/0]).

-define(OPENAI_FILES_URL, "https://api.openai.com/v1/files").
-define(OPENAI_VECTOR_STORES_URL, "https://api.openai.com/v1/vector_stores").
-define(TIMEOUT_MS, 300000).

-type provider() :: anthropic | openai.
-type id() :: binary().
-type file_id() :: binary().

%% Create a managed datasource and return its provider id.
-spec create(provider(), binary() | string()) ->
    {ok, id()} | {error, term()}.
create(anthropic, _Name) ->
    {error, {unsupported_feature, datasource}};
create(openai, Name) when is_binary(Name); is_list(Name) ->
    ensure_started(),
    Headers = openai_headers(),
    Body = json_util:encode(#{<<"name">> => to_bin(Name)}),
    case post(?OPENAI_VECTOR_STORES_URL, Headers, "application/json", Body) of
        {ok, Resp} -> {ok, maps:get(<<"id">>, Resp)};
        Err        -> Err
    end.

%% Delete a managed datasource. Uploaded files remain in provider storage.
-spec delete(provider(), id()) -> ok | {error, term()}.
delete(anthropic, _DatasourceId) ->
    {error, {unsupported_feature, datasource}};
delete(openai, DatasourceId) when is_binary(DatasourceId) ->
    ensure_started(),
    case request_delete(
             openai_vector_store_url(DatasourceId), openai_headers()
         ) of
        {ok, _Resp} -> ok;
        Err         -> Err
    end.

%% Upload local files and attach them to the datasource as one batch.
-spec files_add(provider(), id(), [binary() | string()]) ->
    {ok, map()} | {error, term()}.
files_add(anthropic, _DatasourceId, _FilePaths) ->
    {error, {unsupported_feature, datasource}};
files_add(openai, _DatasourceId, []) ->
    {error, no_files};
files_add(openai, DatasourceId, FilePaths)
  when is_binary(DatasourceId), is_list(FilePaths) ->
    ensure_started(),
    Headers = openai_headers(),
    case upload_openai_files(FilePaths, Headers) of
        {ok, FileIds} ->
            Url = openai_vector_store_url(DatasourceId) ++ "/file_batches",
            Body = json_util:encode(#{<<"file_ids">> => FileIds}),
            case post(Url, Headers, "application/json", Body) of
                {ok, Resp} ->
                    {ok, #{datasource_id => DatasourceId,
                           batch_id => maps:get(<<"id">>, Resp),
                           file_ids => FileIds,
                           status => maps:get(<<"status">>, Resp, undefined)}};
                {error, Reason} ->
                    cleanup_openai_files(FileIds, Headers),
                    {error, {attach_files_failed, Reason}}
            end;
        Err ->
            Err
    end.

%% Detach files from the datasource without deleting the uploaded files.
-spec files_remove(provider(), id(), [file_id()]) ->
    ok | {error, term()}.
files_remove(anthropic, _DatasourceId, _FileIds) ->
    {error, {unsupported_feature, datasource}};
files_remove(openai, DatasourceId, FileIds)
  when is_binary(DatasourceId), is_list(FileIds) ->
    ensure_started(),
    Headers = openai_headers(),
    remove_openai_files(DatasourceId, FileIds, Headers, []).

upload_openai_files(FilePaths, Headers) ->
    upload_openai_files(FilePaths, Headers, []).

upload_openai_files([], _Headers, FileIds) ->
    {ok, lists:reverse(FileIds)};
upload_openai_files([Path | Rest], Headers, FileIds) ->
    case upload_openai_file(Path, Headers) of
        {ok, FileId} ->
            upload_openai_files(Rest, Headers, [FileId | FileIds]);
        {error, Reason} ->
            cleanup_openai_files(FileIds, Headers),
            {error, {upload_file_failed, Path, Reason}}
    end.

upload_openai_file(Path, Headers) ->
    case file:read_file(Path) of
        {ok, Contents} ->
            Boundary = multipart_boundary(),
            Filename = multipart_filename(Path),
            Body = multipart_file_body(Boundary, Filename, Contents),
            ContentType = "multipart/form-data; boundary=" ++ Boundary,
            case post(?OPENAI_FILES_URL, Headers, ContentType, Body) of
                {ok, Resp} -> {ok, maps:get(<<"id">>, Resp)};
                Err        -> Err
            end;
        {error, Reason} ->
            {error, {file, Reason}}
    end.

remove_openai_files(_DatasourceId, [], _Headers, _Removed) ->
    ok;
remove_openai_files(DatasourceId, [FileId | Rest], Headers, Removed) ->
    Url = openai_vector_store_url(DatasourceId)
          ++ "/files/" ++ url_segment(FileId),
    case request_delete(Url, Headers) of
        {ok, _Resp} ->
            remove_openai_files(
                DatasourceId, Rest, Headers, [FileId | Removed]
            );
        {error, Reason} ->
            {error, {remove_file_failed, FileId, Reason,
                     lists:reverse(Removed)}}
    end.

cleanup_openai_files(FileIds, Headers) ->
    lists:foreach(
        fun(FileId) ->
            _ = request_delete(
                ?OPENAI_FILES_URL ++ "/" ++ url_segment(FileId), Headers
            )
        end,
        FileIds
    ).

openai_headers() ->
    [{"authorization", "Bearer " ++ require_env("OPENAI_API_KEY")}].

openai_vector_store_url(DatasourceId) ->
    ?OPENAI_VECTOR_STORES_URL ++ "/" ++ url_segment(DatasourceId).

url_segment(Value) ->
    uri_string:quote(binary_to_list(to_bin(Value))).

multipart_boundary() ->
    "----erlangchain-" ++
        integer_to_list(erlang:unique_integer([positive, monotonic])).

multipart_filename(Path) ->
    Filename = to_bin(filename:basename(Path)),
    lists:foldl(
        fun(Char, Acc) ->
            binary:replace(Acc, <<Char>>, <<"_">>, [global])
        end,
        Filename,
        [$\r, $\n, $"]
    ).

multipart_file_body(Boundary, Filename, Contents) ->
    [["--", Boundary, "\r\n",
      "Content-Disposition: form-data; name=\"purpose\"\r\n\r\n",
      "assistants\r\n"],
     ["--", Boundary, "\r\n",
      "Content-Disposition: form-data; name=\"file\"; filename=\"",
      Filename, "\"\r\n",
      "Content-Type: application/octet-stream\r\n\r\n",
      Contents, "\r\n"],
     ["--", Boundary, "--\r\n"]].

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
        []       -> ok;
        [$# | _] -> ok;
        _        ->
            case string:split(Trimmed, "=") of
                [Key, Val] -> os:putenv(string:trim(Key), string:trim(Val));
                _          -> ok
            end
    end.

post(Url, Headers, ContentType, Body) ->
    Bin = iolist_to_binary(Body),
    case httpc:request(post,
            {Url, Headers, ContentType, Bin},
            [{ssl, [{verify, verify_none}]}, {timeout, ?TIMEOUT_MS}],
            [{body_format, binary}]) of
        {ok, {{_, S, _}, _, RespBody}} when S >= 200, S < 300 ->
            {ok, json_util:decode(RespBody)};
        {ok, {{_, S, _}, _, RespBody}} ->
            {error, {http, S, RespBody}};
        {error, Reason} ->
            {error, Reason}
    end.

request_delete(Url, Headers) ->
    case httpc:request(delete,
            {Url, Headers},
            [{ssl, [{verify, verify_none}]}, {timeout, ?TIMEOUT_MS}],
            [{body_format, binary}]) of
        {ok, {{_, S, _}, _, <<>>}} when S >= 200, S < 300 ->
            {ok, #{}};
        {ok, {{_, S, _}, _, RespBody}} when S >= 200, S < 300 ->
            {ok, json_util:decode(RespBody)};
        {ok, {{_, S, _}, _, RespBody}} ->
            {error, {http, S, RespBody}};
        {error, Reason} ->
            {error, Reason}
    end.

require_env(Name) ->
    case os:getenv(Name) of
        false -> error({missing_env, Name});
        Val   -> Val
    end.

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L)   -> unicode:characters_to_binary(L).
