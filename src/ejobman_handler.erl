%%%
%%% ejobman_handler: gen_server that handles messages from ejobman_receiver
%%%
%%% Copyright (c) 2011 Megaplan Ltd. (Russia)
%%%
%%% Permission is hereby granted, free of charge, to any person obtaining a copy
%%% of this software and associated documentation files (the "Software"),
%%% to deal in the Software without restriction, including without limitation
%%% the rights to use, copy, modify, merge, publish, distribute, sublicense,
%%% and/or sell copies of the Software, and to permit persons to whom
%%% the Software is furnished to do so, subject to the following conditions:
%%%
%%% The above copyright notice and this permission notice shall be included
%%% in all copies or substantial portions of the Software.
%%%
%%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
%%% EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
%%% MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
%%% IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
%%% CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
%%% TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
%%% SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
%%%
%%% @author arkdro <arkdro@gmail.com>
%%% @since 2011-07-15 10:00
%%% @license MIT
%%% @doc a gen_server that gets messages from ejobman_receiver and calls
%%% ejobman_child_supervisor to spawn a new child to do all the dirty work
%%%

-module(ejobman_handler).
-behaviour(gen_server).

%%%----------------------------------------------------------------------------
%%% Exports
%%%----------------------------------------------------------------------------

-export([start/0, start_link/0, stop/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).
-export([terminate/2, code_change/3]).

-export([cmd/1, remove_child/2]).
-export([cmd_result/5]).
-export([get_job_log_filename/0]).
-export([stat_r/0, stat_rss/1, stat_q/0]).

%%%----------------------------------------------------------------------------
%%% Defines
%%%----------------------------------------------------------------------------

-define(DEAD_RIPPING_TIME, 5000000).

%%%----------------------------------------------------------------------------
%%% Includes
%%%----------------------------------------------------------------------------

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-include("ejobman.hrl").
-include("job.hrl").
-include("amqp_client.hrl").

%%%----------------------------------------------------------------------------
%%% gen_server callbacks
%%%----------------------------------------------------------------------------
init(_) ->
    C = ejobman_conf:get_config_hdl(),
    St = prepare_all(C),
    % trap_exit is necessary because the job log is opened
    % trap_exit is unnecessary. Children are ripped by supervisor
    %process_flag(trap_exit, true),
    mpln_p_debug:pr({?MODULE, 'init done', ?LINE}, St#ejm.debug, run, 1),
    {ok, St, ?T}.
%%-----------------------------------------------------------------------------
%%
%% Handling call messages
%% @since 2011-07-15 11:00
%%
-spec handle_call(any(), any(), #ejm{}) ->
    {reply , any(), #ejm{}, non_neg_integer()}
    | {stop, normal, ok, #ejm{}}.

%% @doc returns job log file name
handle_call(get_job_log_filename, _From, St) ->
    New = do_smth(St),
    {reply, New#ejm.jlog_f, New, ?T};

%% @doc set new debug level for facility
handle_call({set_debug_item, Facility, Level}, _From, St) ->
    % no api for this, use message passing
    New = mpln_misc_run:update_debug_level(St#ejm.debug, Facility, Level),
    {reply, St#ejm.debug, St#ejm{debug=New}, ?T};

%% @doc returns statistic for the last running jobs
handle_call(stat_r, _From, St) ->
    {reply, St#ejm.stat_r, St, ?T};

%% @doc returns state of queues
handle_call(stat_q, _From, St) ->
    Res = ejobman_handler_cmd:make_stat_queue_info(St),
    {reply, Res, St, ?T};

%% @doc returns statistic for the last running jobs as an rss
handle_call({stat_rss, N}, _From, St) ->
    mpln_p_debug:pr({?MODULE, 'call stat_rss', ?LINE, N}, St#ejm.debug, run, 3),
    Res = ejobman_log:get_last_jobs_rss(St, N),
    {reply, Res, St, ?T};

handle_call(stop, _From, St) ->
    {stop, normal, ok, St};
handle_call(status, _From, St) ->
    {reply, St, St, ?T};
handle_call(_N, _From, St) ->
    mpln_p_debug:pr({?MODULE, 'other', ?LINE, _N}, St#ejm.debug, run, 2),
    New = do_smth(St),
    {reply, {error, unknown_request}, New, ?T}.
%%-----------------------------------------------------------------------------
%%
%% Handling cast messages
%% @since 2011-07-15 11:00
%%
-spec handle_cast(any(), #ejm{}) -> any().

handle_cast(stop, St) ->
    {stop, normal, St};

%% @doc calls disposable child
handle_cast({cmd, Job}, St) ->
    St_d = do_smth(St),
    New = ejobman_handler_cmd:do_command(St_d, 'From', Job),
    mpln_p_debug:pr({?MODULE, 'cmd started', ?LINE}, St#ejm.debug, run, 3),
    {noreply, New, ?T};

%% @doc result of work of disposable child
handle_cast({cmd_result, Res, T1, T2, Group, Id}, St) ->
    Dur = timer:now_diff(T2, T1),
    mpln_p_debug:pr({?MODULE, 'cast cmd res', ?LINE, Group, Id, Dur},
        St#ejm.debug, run, 2),
    St_r = ejobman_handler_cmd:do_command_result(St, Res, T1, T2, Group, Id),
    New = do_smth(St_r),
    {noreply, New, ?T};

%% @doc deletes disposable child from the state
handle_cast({remove_child, Pid, Group}, St) ->
    mpln_p_debug:pr({?MODULE, "remove child", ?LINE, Pid, Group},
        St#ejm.debug, run, 4),
    St_r = ejobman_handler_cmd:remove_child(St, Pid, Group),
    New = do_smth(St_r),
    {noreply, New, ?T};

handle_cast(_N, St) ->
    mpln_p_debug:pr({?MODULE, 'cast other', ?LINE, _N}, St#ejm.debug, run, 2),
    New = do_smth(St),
    {noreply, New, ?T}.

%%-----------------------------------------------------------------------------
%%
%% @doc Note: it won't be called unless trap_exit is set
%%
terminate(_, State) ->
    close_job_log(State),
    mpln_p_debug:pr({?MODULE, 'terminate', ?LINE}, State#ejm.debug, run, 1),
    ok.

%%-----------------------------------------------------------------------------
%%
%% Handling all non call/cast messages
%% @since 2011-07-15 11:00
%%
-spec handle_info(any(), #ejm{}) -> {noreply, #ejm{}, non_neg_integer()}.

handle_info(timeout, State) ->
    mpln_p_debug:pr({?MODULE, info_timeout, ?LINE}, State#ejm.debug, run, 6),
    New = do_smth(State),
    {noreply, New, ?T};
handle_info(_Req, State) ->
    mpln_p_debug:pr({?MODULE, other, ?LINE, _Req}, State#ejm.debug, run, 2),
    New = do_smth(State),
    {noreply, New, ?T}.

%%-----------------------------------------------------------------------------
code_change(_Old_vsn, State, _Extra) ->
    {ok, State}.

%%%----------------------------------------------------------------------------
%%% API
%%%----------------------------------------------------------------------------
-spec start() -> any().
%%
%% @doc starts handler gen_server
%% @since 2011-07-15 11:00
%%
start() ->
    start_link().

%%-----------------------------------------------------------------------------
-spec start_link() -> any().
%%
%% @doc starts handler gen_server with pre-defined config
%% @since 2011-07-15 11:00
%%
start_link() ->
    start_link(?CONF).

-spec start_link(string()) -> any().
%%
%% @doc starts handler gen_server with given config
%% @since 2011-07-15 11:00
%%
start_link(Config) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Config, []).

%%-----------------------------------------------------------------------------
-spec stop() -> any().
%%
%% @doc stops handler gen_server
%% @since 2011-07-15 11:00
%%
stop() ->
    gen_server:call(?MODULE, stop).

%%-----------------------------------------------------------------------------
%%
%% @doc sends received command to be executed by disposable child
%% @since 2011-07-15 11:00
%%
-spec cmd(#job{}) -> ok.

cmd(Job) ->
    gen_server:cast(?MODULE, {cmd, Job}).

%%-----------------------------------------------------------------------------
%%
%% @doc sends message to server to log cmd result
%% @since 2011-07-15 11:00
%%
-spec cmd_result(tuple(), tuple(), tuple(),
    default | binary(), reference()) -> ok.

cmd_result(Res, T1, T2, Group, Id) ->
    gen_server:cast(?MODULE, {cmd_result, Res, T1, T2, Group, Id}).

%%-----------------------------------------------------------------------------
%%
%% @doc asks ejobman_handler for job log file name
%%
-spec get_job_log_filename() -> string() | undefined.

get_job_log_filename() ->
    gen_server:call(?MODULE, get_job_log_filename).

%%-----------------------------------------------------------------------------
%%
%% @doc asks ejobman_handler to remove child from the list
%%
-spec remove_child(pid(), any()) -> ok.

remove_child(Pid, Group) ->
    gen_server:cast(?MODULE, {remove_child, Pid, Group}).

%%-----------------------------------------------------------------------------
%%
%% @doc asks ejobman_handler for state of queues
%%
-spec stat_q() -> dict().

stat_q() ->
    gen_server:call(?MODULE, stat_q).

%%-----------------------------------------------------------------------------
%%
%% @doc asks ejobman_handler for statistic for the last jobs
%%
-spec stat_r() -> dict().

stat_r() ->
    gen_server:call(?MODULE, stat_r).

%%-----------------------------------------------------------------------------
%%
%% @doc asks ejobman_handler for statistic for the last jobs as rss
%%
-spec stat_rss(non_neg_integer()) -> binary().

stat_rss(N) ->
    gen_server:call(?MODULE, {stat_rss, N}).

%%%----------------------------------------------------------------------------
%%% Internal functions
%%%----------------------------------------------------------------------------
%%
%% @doc does miscellaneous periodic checks. E.g.: check for children. Returns
%% updated state.
%%
-spec do_smth(#ejm{}) -> #ejm{}.

do_smth(State) ->
    St = job_log_rotate(State),
    mpln_p_debug:pr({?MODULE, 'do_smth', ?LINE}, St#ejm.debug, run, 5),
    Stc = check_children(St),
    check_queued_commands(Stc).

%%-----------------------------------------------------------------------------
%%
%% @doc calls to process all the queued commands
%%
-spec check_queued_commands(#ejm{}) -> #ejm{}.

check_queued_commands(St) ->
    ejobman_handler_cmd:do_short_commands(St).

%%-----------------------------------------------------------------------------
%%
%% @doc checks that all the children are alive. Returns new state with
%% live children and marked dead ones
%% @todo rewrite it to use monitors
%%
check_children(#ejm{ch_data=Data} = St) ->
    F1 = fun(_Gid, List) ->
        lists:map(fun mark_child/1, List)
    end,
    Data2 = dict:map(F1, Data),
    F2 = fun(_Gid, List) ->
        lists:filter(fun check_child/1, List)
    end,
    New_data = dict:map(F2, Data2),
    St#ejm{ch_data=New_data}.

%%-----------------------------------------------------------------------------
%%
%% @doc mark dead child to be ripped later
%%
-spec mark_child(#chi{}) -> #chi{}.

mark_child(#chi{pid=Pid} = Info) ->
    case process_info(Pid, reductions) of
        {reductions, _N} ->
            Info;
        _ ->
            Info#chi{alive=false, stop=now()}
    end.

%%-----------------------------------------------------------------------------
%%
%% @doc checks whether the given child does something
%%
-spec check_child(#chi{}) -> boolean().

check_child(#chi{alive=false, stop=T}) ->
    Delta = timer:now_diff(now(), T),
    Delta < ?DEAD_RIPPING_TIME;

check_child(_) ->
    true.

%%-----------------------------------------------------------------------------
%%
%% @doc prepares necessary things
%%
-spec prepare_all(#ejm{}) -> #ejm{}.

prepare_all(St) ->
    St_st = prepare_stat(St),
    prepare_job_log(St_st).

%%-----------------------------------------------------------------------------
%%
%% @doc prepares statistic
%%
prepare_stat(St) ->
    St#ejm{
        stat_t = dict:new(), % aggregated by time. Hash: time, status -> data
        stat_r = dict:new()  % last N jobs. Hash: ref -> item
    }.

%%-----------------------------------------------------------------------------
%%
%% @doc prepares log for jobs and results
%%
-spec prepare_job_log(#ejm{}) -> #ejm{}.

prepare_job_log(#ejm{job_log=undefined} = St) ->
    St;
prepare_job_log(#ejm{job_log=Base} = St) ->
    File = mpln_misc_log:get_fname(Base),
    filelib:ensure_dir(File),
    case file:open(File, [raw, append, binary]) of
        {ok, Fd} ->
            St#ejm{jlog=Fd, jlog_f=File};
        {error, Reason} ->
            mpln_p_debug:pr({?MODULE, "prepare_job_log error", ?LINE, Reason},
                St#ejm.debug, run, 0),
            St#ejm{jlog_f=undefined}
    end.

%%-----------------------------------------------------------------------------
%%
%% @doc close log with jobs
%%
close_job_log(#ejm{jlog = undefined}) ->
    ok;
close_job_log(#ejm{jlog = Fd}) ->
    file:close(Fd).

%%-----------------------------------------------------------------------------
%%
%% @doc rotates job log only. Does not touch error log.
%%
-spec job_log_rotate(#ejm{}) -> #ejm{}.

job_log_rotate(#ejm{job_log_last=Last, job_log_rotate=Dur} = St) ->
    case mpln_misc_log:need_rotate(Last, Dur) of
        true ->
            close_job_log(St),
            St_f = prepare_job_log(St),
            St_f#ejm{job_log_last = calendar:local_time()};
        false ->
            St
    end.

%%%----------------------------------------------------------------------------
%%% EUnit tests
%%%----------------------------------------------------------------------------
-ifdef(TEST).
remove_child_test() ->
    Pid = self(),
    Me = #chi{pid=Pid, start=now()},
    Ch = make_fake_children(),
    St = #ejm{ch_data = [Me | Ch]},
    ?assert(#ejm{ch_data=Ch} =:= remove_child(St, Pid)).

check_mix_children_test() ->
    Me = #chi{pid=self(), start=now()},
    Ch = make_fake_children(),
    St = #ejm{ch_data = [Me | Ch]},
    ?assert(#ejm{ch_data=[Me]} =:= check_children(St)).
 
check_fake_children_test() ->
    Ch = make_fake_children(),
    St = #ejm{ch_data = Ch},
    ?assert(#ejm{ch_data=[]} =:= check_children(St)).
 
make_fake_children() ->
    L = [
        "<0.12340.5678>",
        "<0.32767.7136>",
        "<0.7575.5433>"
    ],
    lists:map(fun(X) -> #chi{pid=list_to_pid(X), start=now()} end, L).
-endif.
%%-----------------------------------------------------------------------------
