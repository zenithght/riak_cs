%% -------------------------------------------------------------------
%%
%% Copyright (c) 2007-2012 Basho Technologies, Inc.  All Rights Reserved.
%%
%% -------------------------------------------------------------------

-module(riak_cs_wm_object).

-export([init/1,
         authorize/2,
         content_types_provided/2,
         produce_body/2,
         allowed_methods/2,
         content_types_accepted/2,
         accept_body/2,
         delete_resource/2,
         valid_entity_length/2,
         finish_request/2]).
-export([dt_return_object/3]).

-include("riak_cs.hrl").
-include_lib("webmachine/include/webmachine.hrl").

-record(key_context, {context :: #context{},
                      manifest :: 'notfound' | lfs_manifest(),
                      get_fsm_pid :: pid(),
                      putctype :: string(),
                      bucket :: binary(),
                      key :: list(),
                      owner :: 'undefined' | string(),
                      size :: non_neg_integer()}).

init(Config) ->
    {ok, Ctx} = riak_cs_wm_common:init(Config),
    {ok, Ctx#context{local_context=#key_context{}}}.

%% @doc Get the type of access requested and the manifest with the
%% object ACL and compare the permission requested with the permission
%% granted, and allow or deny access. Returns a result suitable for
%% directly returning from the {@link forbidden/2} webmachine export.
authorize(RD, Ctx=#context{local_context=LocalCtx}) ->
    Method = wrq:method(RD),
    RequestedAccess =
        riak_cs_acl_utils:requested_access(Method,
                                           wrq:req_qs(RD)),
     %% @TODO This line is no longer needed post-refactor
    NewLocalCtx0 = LocalCtx#context{requested_perm=RequestedAccess},
    NewLocalCtx = riak_cs_wm_utils:ensure_doc(NewLocalCtx0),
    NewCtx = riak_cs_wm_utils:ensure_doc(Ctx#context{local_context=NewLocalCtx}),
    check_permission(Method, RD, NewCtx, NewLocalCtx#key_context.manifest).

%% @doc Final step of {@link forbidden/2}: Authentication succeeded,
%% now perform ACL check to verify access permission.
check_permission('GET', RD, Ctx, notfound) ->
    {{halt, 404}, maybe_log_user(RD, Ctx), Ctx};
check_permission('HEAD', RD, Ctx, notfound) ->
    {{halt, 404}, maybe_log_user(RD, Ctx), Ctx};
check_permission(Method, RD, Ctx=#context{local_context=LocalCtx}, Mfst) ->
    #key_context{bucket=Bucket} = LocalCtx,
    RiakPid = Ctx#context.riakc_pid,
    RequestedAccess =
        riak_cs_acl_utils:requested_access(Method,
                                           wrq:req_qs(RD)),
    case Ctx#context.user of
        undefined ->
            User = CanonicalId = undefined;
        User ->
            CanonicalId = User?RCS_USER.canonical_id
    end,
    case Mfst of
        notfound ->
            ObjectAcl = undefined;
        _ ->
            ObjectAcl = Mfst?MANIFEST.acl
    end,
    case riak_cs_acl:object_access(Bucket,
                                   ObjectAcl,
                                   RequestedAccess,
                                   CanonicalId,
                                   RiakPid) of
        true ->
            %% actor is the owner
            AccessRD = riak_cs_access_logger:set_user(User, RD),
            UserStr = User?RCS_USER.canonical_id,
            UpdLocalCtx = LocalCtx#key_context{owner=UserStr},
            {false, AccessRD, Ctx#context{local_context=UpdLocalCtx}};
        {true, OwnerId} ->
            %% bill the owner, not the actor
            AccessRD = riak_cs_access_logger:set_user(OwnerId, RD),
            UpdLocalCtx = LocalCtx#key_context{owner=OwnerId},
            {false, AccessRD, Ctx#context{local_context=UpdLocalCtx}};
        false ->
            %% ACL check failed, deny access
            riak_cs_wm_utils:deny_access(RD, Ctx)
    end.

%% @doc Only set the user for the access logger to catch if there is a
%% user to catch.
maybe_log_user(RD, Context) ->
    case Context#context.user of
        undefined ->
            RD;
        User ->
            riak_cs_access_logger:set_user(User, RD)
    end.

%% @doc Get the list of methods this resource supports.
-spec allowed_methods(term(), term()) -> {[atom()], term(), term()}.
allowed_methods(RD, Ctx) ->
    %% TODO: POST
    {['HEAD', 'GET', 'DELETE', 'PUT'], RD, Ctx}.

valid_entity_length(RD, Ctx=#context{local_context=LocalCtx}) ->
    case wrq:method(RD) of
        'PUT' ->
            case catch(
                   list_to_integer(
                     wrq:get_req_header("Content-Length", RD))) of
                Length when is_integer(Length) ->
                    case Length =< riak_cs_lfs_utils:max_content_len() of
                        false ->
                            riak_cs_s3_response:api_error(
                              entity_too_large, RD, Ctx);
                        true ->
                            UpdLocalCtx = LocalCtx#key_context{size=Length},
                            {true, RD, Ctx#context{local_context=UpdLocalCtx}}
                    end;
                _ ->
                    {false, RD, Ctx}
            end;
        _ ->
            {true, RD, Ctx}
    end.

-spec content_types_provided(term(), term()) ->
    {[{string(), atom()}], term(), term()}.
content_types_provided(RD, Ctx=#context{local_context=LocalCtx,
                                        riakc_pid=RiakcPid}) ->
    Mfst = LocalCtx#key_context.manifest,
    dt_entry(<<"content_types_provided">>),
    %% TODO:
    %% As I understand S3, the content types provided
    %% will either come from the value that was
    %% last PUT or, from you adding a
    %% `response-content-type` header in the request.
    Method = wrq:method(RD),
    if Method == 'GET'; Method == 'HEAD' ->
            UpdLocalCtx = ensure_doc(LocalCtx, RiakcPid),
            ContentType = binary_to_list(Mfst?MANIFEST.content_type),
            case ContentType of
                _ ->
                    UpdCtx = Ctx#context{local_context=UpdLocalCtx},
                    {[{ContentType, produce_body}], RD, UpdCtx}
            end;
       true ->
            %% TODO this shouldn't ever be called, it's just to
            %% appease webmachine
            {[{"text/plain", produce_body}], RD, Ctx}
    end.

-spec produce_body(term(), term()) -> {iolist()|binary(), term(), term()}.
produce_body(RD, Ctx=#context{local_context=LocalCtx,
                              start_time=StartTime,
                              user=User}) ->
    #key_context{get_fsm_pid=GetFsmPid, manifest=Mfst} = LocalCtx,
    {Bucket, File} = Mfst?MANIFEST.bkey,
    BFile_str = [Bucket, $,, File],
    UserName = extract_name(User),
    dt_entry(<<"produce_body">>, [], [UserName, BFile_str]),
    dt_entry_object(<<"file_get">>, [], [UserName, BFile_str]),
    ContentLength = Mfst?MANIFEST.content_length,
    ContentMd5 = Mfst?MANIFEST.content_md5,
    LastModified = riak_cs_wm_utils:to_rfc_1123(Mfst?MANIFEST.created),
    ETag = "\"" ++ riak_cs_utils:binary_to_hexlist(ContentMd5) ++ "\"",
    NewRQ = lists:foldl(fun({K, V}, Rq) -> wrq:set_resp_header(K, V, Rq) end,
                        RD,
                        [{"ETag",  ETag},
                         {"Last-Modified", LastModified}
                        ] ++  Mfst?MANIFEST.metadata),
    Method = wrq:method(RD),
    case Method == 'HEAD'
        orelse
    ContentLength == 0 of
        true ->
            riak_cs_get_fsm:stop(GetFsmPid),
            StreamFun = fun() -> {<<>>, done} end;
        false ->
            riak_cs_get_fsm:continue(GetFsmPid),
            StreamFun = fun() -> riak_cs_wm_utils:streaming_get(
                                   GetFsmPid, StartTime, UserName, BFile_str)
                        end
    end,
    if Method == 'HEAD' ->
            dt_return_object(<<"file_head">>, [], [UserName, BFile_str]),
            ok = riak_cs_stats:update_with_start(object_head, StartTime);
       true ->
            ok
    end,
    dt_return(<<"produce_body">>, [ContentLength], [UserName, BFile_str]),
    {{known_length_stream, ContentLength, {<<>>, StreamFun}}, NewRQ, Ctx}.

%% @doc Callback for deleting an object.
-spec delete_resource(term(), term()) -> {true, term(), #key_context{}}.
delete_resource(RD, Ctx=#context{local_context=LocalCtx,
                                 riakc_pid=RiakcPid}) ->
    #key_context{bucket=Bucket,
                 key=Key,
                 get_fsm_pid=GetFsmPid} = LocalCtx,
    BFile_str = [Bucket, $,, Key],
    UserName = extract_name(Ctx#context.user),
    dt_entry(<<"delete_resource">>, [], [UserName, BFile_str]),
    dt_entry_object(<<"file_delete">>, [], [UserName, BFile_str]),
    riak_cs_get_fsm:stop(GetFsmPid),
    BinKey = list_to_binary(Key),
    DeleteObjectResponse = riak_cs_utils:delete_object(Bucket, BinKey, RiakcPid),
    handle_delete_object(DeleteObjectResponse, UserName, BFile_str, RD, Ctx).

%% @private
handle_delete_object({error, Error}, UserName, BFile_str, RD, Ctx) ->
    lager:error("delete object failed with reason: ", [Error]),
    dt_return(<<"delete_resource">>, [0], [UserName, BFile_str]),
    dt_return_object(<<"file_delete">>, [0], [UserName, BFile_str]),
    {false, RD, Ctx};
handle_delete_object({ok, _UUIDsMarkedforDelete}, UserName, BFile_str, RD, Ctx) ->
    dt_return(<<"delete_resource">>, [1], [UserName, BFile_str]),
    dt_return_object(<<"file_delete">>, [1], [UserName, BFile_str]),
    {true, RD, Ctx}.

-spec content_types_accepted(term(), term()) ->
    {[{string(), atom()}], term(), term()}.
content_types_accepted(RD, Ctx) ->
    dt_entry(<<"content_types_accepted">>),
    case wrq:get_req_header("Content-Type", RD) of
        undefined ->
            DefaultCType = "application/octet-stream",
            {[{DefaultCType, accept_body}],
             RD,
             Ctx#key_context{putctype=DefaultCType}};
        %% This was shamelessly ripped out of
        %% https://github.com/basho/riak_kv/blob/0d91ca641a309f2962a216daa0cee869c82ffe26/src/riak_kv_wm_object.erl#L492
        CType ->
            {Media, _Params} = mochiweb_util:parse_header(CType),
            case string:tokens(Media, "/") of
                [_Type, _Subtype] ->
                    %% accept whatever the user says
                    {[{Media, accept_body}], RD, Ctx#key_context{putctype=Media}};
                _ ->
                    %% TODO:
                    %% Maybe we should have caught
                    %% this in malformed_request?
                    {[],
                     wrq:set_resp_header(
                       "Content-Type",
                       "text/plain",
                       wrq:set_resp_body(
                         ["\"", Media, "\""
                          " is not a valid media type"
                          " for the Content-type header.\n"],
                         RD)),
                     Ctx}
            end
    end.

accept_body(RD, Ctx=#context{local_context=LocalCtx,
                             user=User,
                             riakc_pid=RiakcPid}) ->
    #key_context{bucket=Bucket,
                 key=Key,
                 putctype=ContentType,
                 size=Size,
                 get_fsm_pid=GetFsmPid,
                 owner=Owner} = LocalCtx,
    BFile_str = [Bucket, $,, Key],
    UserName = extract_name(User),
    dt_entry(<<"accept_body">>, [], [UserName, BFile_str]),
    dt_entry_object(<<"file_put">>, [], [UserName, BFile_str]),
    riak_cs_get_fsm:stop(GetFsmPid),
    Metadata = riak_cs_wm_utils:extract_user_metadata(RD),
    BlockSize = riak_cs_lfs_utils:block_size(),
    %% Check for `x-amz-acl' header to support
    %% non-default ACL at bucket creation time.
    ACL = riak_cs_acl_utils:canned_acl(
            wrq:get_req_header("x-amz-acl", RD),
            {User?RCS_USER.display_name,
             User?RCS_USER.canonical_id,
             User?RCS_USER.key_id},
            Owner,
            RiakcPid),
    Args = [{Bucket, list_to_binary(Key), Size, list_to_binary(ContentType),
             Metadata, BlockSize, ACL, timer:seconds(60), self(), RiakcPid}],
    {ok, Pid} = riak_cs_put_fsm_sup:start_put_fsm(node(), Args),
    accept_streambody(RD, Ctx, Pid, wrq:stream_req_body(RD, riak_cs_lfs_utils:block_size())).

accept_streambody(RD,
                  Ctx=#context{local_context=_LocalCtx=#key_context{size=0}},
                  Pid,
                  {_Data, _Next}) ->
    finalize_request(RD, Ctx, Pid);
accept_streambody(RD,
                  Ctx=#context{local_context=LocalCtx,
                                       user=User},
                  Pid,
                  {Data, Next}) ->
    #key_context{bucket=Bucket,
                 key=Key} = LocalCtx,
    BFile_str = [Bucket, $,, Key],
    UserName = extract_name(User),
    dt_entry(<<"accept_streambody">>, [size(Data)], [UserName, BFile_str]),
    riak_cs_put_fsm:augment_data(Pid, Data),
    if is_function(Next) ->
            accept_streambody(RD, Ctx, Pid, Next());
       Next =:= done ->
            finalize_request(RD, Ctx, Pid)
    end.

%% TODO:
%% We need to do some checking to make sure
%% the bucket exists for the user who is doing
%% this PUT
finalize_request(RD,
                 Ctx=#context{local_context=LocalCtx,
                              start_time=StartTime,
                              user=User},
                 Pid) ->
    #key_context{bucket=Bucket,
                 key=Key,
                 size=S} = LocalCtx,
    BFile_str = [Bucket, $,, Key],
    UserName = extract_name(User),
    dt_entry(<<"finalize_request">>, [S], [UserName, BFile_str]),
    dt_entry_object(<<"file_put">>, [S], [UserName, BFile_str]),
    %% TODO: probably want something that counts actual bytes uploaded
    %% instead, to record partial/aborted uploads
    AccessRD = riak_cs_access_logger:set_bytes_in(S, RD),

    {ok, Manifest} = riak_cs_put_fsm:finalize(Pid),
    ETag = "\"" ++ riak_cs_utils:binary_to_hexlist(Manifest?MANIFEST.content_md5) ++ "\"",
    ok = riak_cs_stats:update_with_start(object_put, StartTime),
    dt_return(<<"finalize_request">>, [S], [UserName, BFile_str]),
    {{halt, 200}, wrq:set_resp_header("ETag",  ETag, AccessRD), Ctx}.

finish_request(RD, Ctx=#context{local_context=LocalCtx,
                                riakc_pid=RiakcPid,
                                user=User}) ->
    #key_context{bucket=Bucket,
                 key=Key} = LocalCtx,
    BFile_str = [Bucket, $,, Key],
    UserName = extract_name(User),
    dt_entry(<<"finish_request">>, [], [UserName, BFile_str]),
    case RiakcPid of
        undefined ->
            dt_return(<<"finish_request">>, [0], [UserName, BFile_str]),
            {true, RD, LocalCtx};
        _ ->
            riak_cs_utils:close_riak_connection(RiakcPid),
            UpdCtx = Ctx#context{riakc_pid=undefined},
            dt_return(<<"finish_request">>, [1], [UserName, BFile_str]),
            {true, RD, UpdCtx}
    end.

extract_name(X) ->
    riak_cs_wm_utils:extract_name(X).

%% @doc Utility function for accessing
%%      a riakc_obj without retrieving
%%      it again if it's already in the
%%      Ctx
-spec ensure_doc(term(), pid()) -> term().
ensure_doc(KeyCtx=#key_context{get_fsm_pid=undefined,
                               bucket=Bucket,
                               key=Key}, RiakcPid) ->
    %% start the get_fsm
    BinKey = list_to_binary(Key),
    {ok, Pid} = riak_cs_get_fsm_sup:start_get_fsm(node(), Bucket, BinKey, self(), RiakcPid),
    Manifest = riak_cs_get_fsm:get_manifest(Pid),
    KeyCtx#key_context{get_fsm_pid=Pid, manifest=Manifest};
ensure_doc(KeyCtx, _) ->
    KeyCtx.

dt_entry(Func) ->
    dt_entry(Func, [], []).

dt_entry(Func, Ints, Strings) ->
    riak_cs_dtrace:dtrace(?DT_WM_OP, 1, Ints, ?MODULE, Func, Strings).

dt_entry_object(Func, Ints, Strings) ->
    riak_cs_dtrace:dtrace(?DT_OBJECT_OP, 1, Ints, ?MODULE, Func, Strings).

dt_return(Func, Ints, Strings) ->
    riak_cs_dtrace:dtrace(?DT_WM_OP, 2, Ints, ?MODULE, Func, Strings).

dt_return_object(Func, Ints, Strings) ->
    riak_cs_dtrace:dtrace(?DT_OBJECT_OP, 2, Ints, ?MODULE, Func, Strings).