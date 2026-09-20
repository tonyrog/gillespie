%%% @author Tony Rogvall <tony@rogvall.se>
%%% @copyright (C) 2026, Tony Rogvall
%%% @doc
%%%    Multi device LPC flash tool (built on elpcisp).
%%%
%%%    All boards sit on one big PCB and are programmed in a batch
%%%    of up to N uarts (10 today).  One process per uart, all of them
%%%    write the same firmware image.
%%% @end
%%% Created : 19 Sep 2026

-module(gillespie).

-export([start/0, gui/0]).
-export([list_devices/0]).
-export([devices/0, scan/0]).
-export([flash/0, flash/1]).
-export([config/0, config_file/0, save_config/1]).
-export([options/1, firmware_size/2]).
-export([flash_device/5]).

-include_lib("kernel/include/file.hrl").

-define(APP, ?MODULE).
-define(SEGMENT_SIZE, 256).

-define(DEFAULT_BAUD,       115200).
-define(DEFAULT_OSCILLATOR, 12000).   %% kHz
-define(DEFAULT_ADDR,       0).
-define(DEFAULT_SYNC_RETRY, 3).
-define(DEFAULT_SYNC_TMO,   2000).
-define(DEFAULT_FILENAME,   "firmware.bin").

-type devno() :: integer().
-type config() :: #{ uart_list  => [{devno(), string(), boolean()}],
		     filename   => string(),
		     baud       => integer(),
		     flash_baud => integer(),
		     oscillator => integer(),
		     addr       => integer(),
		     sync_retry => integer(),
		     sync_tmo   => integer(),
		     control    => boolean(),
		     control_inv => boolean(),
		     control_swap => boolean() }.

-type event() :: {phase, atom()} |
		 {info, [{atom(),term()}]} |
		 {progress, Written::integer(), Total::integer()} |
		 done |
		 {error, Phase::atom(), Reason::term()}.

-type report() :: fun((devno(), event()) -> any()).

-export_type([config/0, event/0, report/0]).

start() ->
    application:ensure_all_started(?APP).

%% start the wx gui
gui() ->
    start(),
    gillespie_wx:start().

%%--------------------------------------------------------------------
%% Configuration
%%--------------------------------------------------------------------

%% @doc
%%   Read application environment into a config map with defaults.
%%   uart_list entries may be {No,Pattern} or {No,Pattern,Opts} where
%%   Opts is a proplist, currently only {enable,boolean()}.
%% @end
-spec config() -> config().
config() ->
    _ = application:load(?APP),
    Env = application:get_all_env(?APP),
    Baud = proplists:get_value(baud, Env, ?DEFAULT_BAUD),
    #{ uart_list  => [uart_entry(E) ||
			 E <- proplists:get_value(uart_list, Env, [])],
       filename   => proplists:get_value(filename, Env, ?DEFAULT_FILENAME),
       baud       => Baud,
       flash_baud => proplists:get_value(flash_baud, Env, Baud),
       oscillator => proplists:get_value(oscillator, Env, ?DEFAULT_OSCILLATOR),
       addr       => proplists:get_value(addr, Env, ?DEFAULT_ADDR),
       sync_retry => proplists:get_value(sync_retry, Env, ?DEFAULT_SYNC_RETRY),
       sync_tmo   => proplists:get_value(sync_tmo, Env, ?DEFAULT_SYNC_TMO),
       control    => proplists:get_value(control, Env, false),
       control_inv  => proplists:get_value(control_inv, Env, false),
       control_swap => proplists:get_value(control_swap, Env, false)
     }.

uart_entry({No, Pattern}) ->
    {No, Pattern, true};
uart_entry({No, Pattern, Opts}) ->
    {No, Pattern, proplists:get_value(enable, Opts, true)}.

uart_term({No, Pattern, true}) -> {No, Pattern};
uart_term({No, Pattern, false}) -> {No, Pattern, [{enable,false}]}.

%% @doc
%%   The config file we read (and save to). Taken from the -config
%%   argument given to erl, default "local.config".
%% @end
-spec config_file() -> string().
config_file() ->
    case init:get_argument(config) of
	{ok, [[Name|_]|_]} ->
	    case filename:extension(Name) of
		".config" -> Name;
		_ -> Name ++ ".config"
	    end;
	_ ->
	    "local.config"
    end.

%% @doc
%%   Save config map to the config file. Other applications in the
%%   file are preserved. The running application environment is
%%   updated as well.
%% @end
-spec save_config(config()) -> {ok, string()} | {error, term()}.
save_config(Config) ->
    File = config_file(),
    Terms = case file:consult(File) of
		{ok, [L]} when is_list(L) -> L;
		_ -> []
	    end,
    Env = config_to_env(Config),
    Others = lists:keydelete(?APP, 1, Terms),
    Data = ["%% -*- erlang -*-\n",
	    "%% written by gillespie ", timestamp(), "\n",
	    "[", format_env(Env),
	    [io_lib:format(",\n ~p", [T]) || T <- Others],
	    "\n].\n"],
    case file:write_file(File, Data) of
	ok ->
	    lists:foreach(fun({K,V}) -> application:set_env(?APP, K, V) end,
			  Env),
	    {ok, File};
	Error ->
	    Error
    end.

config_to_env(Config) ->
    #{ uart_list := UartList } = Config,
    [{uart_list, [uart_term(U) || U <- UartList]} |
     [{K, maps:get(K, Config)} ||
	 K <- [filename, baud, flash_baud, oscillator, addr,
	       sync_retry, sync_tmo, control, control_inv, control_swap]]].

%% one uart per line, one option per line
format_env([{uart_list, UartList}|Env]) ->
    Uarts = lists:join(",\n     ", [io_lib:format("~p", [U]) || U <- UartList]),
    ["{", atom_to_list(?APP), ",\n  [{uart_list,\n    [", Uarts, "]}",
     [io_lib:format(",\n   ~p", [KV]) || KV <- Env],
     "\n  ]}"].

timestamp() ->
    {{Y,M,D},{H,Mi,S}} = calendar:local_time(),
    io_lib:format("~4..0w-~2..0w-~2..0w ~2..0w:~2..0w:~2..0w",
		  [Y,M,D,H,Mi,S]).

%% @doc
%%   Build the elpcisp option map from a config map.
%% @end
-spec options(config()) -> map().
options(Config) ->
    #{ baud => maps:get(baud, Config),
       flash_baud => maps:get(flash_baud, Config),
       oscillator => maps:get(oscillator, Config),
       sync_retry => maps:get(sync_retry, Config),
       sync_tmo => maps:get(sync_tmo, Config),
       control => maps:get(control, Config),
       control_inv => maps:get(control_inv, Config),
       control_swap => maps:get(control_swap, Config),
       addr => maps:get(addr, Config),
       segment_size => ?SEGMENT_SIZE
     }.

%%--------------------------------------------------------------------
%% Devices
%%--------------------------------------------------------------------

%% list devices attached
list_devices() ->
    lists:foreach(
      fun({DevNo, Pattern, Enabled, Device}) ->
	      Status = case Device of
			   undefined -> "NOT PRESENT";
			   _ -> Device
		       end,
	      En = if Enabled -> ""; true -> " (disabled)" end,
	      io:format("~w: ~s ~s~s\n", [DevNo, Pattern, Status, En])
      end, scan()).

%% @doc
%%   Scan all configured uarts.
%%   Return [{DevNo, Pattern, Enabled, Device | undefined}]
%% @end
-spec scan() -> [{devno(), string(), boolean(), string() | undefined}].
scan() ->
    #{ uart_list := UartList } = config(),
    [{DevNo, Pattern, Enabled, resolve(Pattern)} ||
	{DevNo, Pattern, Enabled} <- UartList].

%% return list of enabled devices present as [{DevNo, Device}]
devices() ->
    {ok, [{DevNo, Device} || {DevNo, _Pattern, true, Device} <- scan(),
			     Device =/= undefined]}.

%% resolve a device pattern into a real device file name or undefined
resolve(Pattern) ->
    case filelib:wildcard(Pattern) of
	[Filename] ->
	    case is_device(Filename) of
		true -> canonical(Filename);
		false -> undefined
	    end;
	_ ->
	    undefined
    end.

is_device(Filename) ->
    case file:read_file_info(Filename) of
	{ok, FI} ->
	    FI#file_info.type =:= device;
	{error, _} ->
	    false
    end.

%% follow symlink (/dev/serial/by-path/... -> ../../ttyUSB0)
canonical(Filename) ->
    case file:read_link(Filename) of
	{ok, Target} ->
	    Abs = filename:absname(Target, filename:dirname(Filename)),
	    Parts = lists:foldl(
		      fun("..", [_|Acc]) -> Acc;
			 ("..", []) -> [];
			 (".", Acc) -> Acc;
			 (P, Acc) -> [P|Acc]
		      end, [], filename:split(Abs)),
	    filename:join(lists:reverse(Parts));
	_ ->
	    Filename
    end.

%%--------------------------------------------------------------------
%% Flash (command line)
%%--------------------------------------------------------------------

flash() ->
    #{ filename := Filename } = config(),
    flash(Filename).

flash(Filename) ->
    {ok, DeviceList} = devices(),
    Opts = options(config()),
    Report = fun(DevNo, Event) -> report(DevNo, Event) end,
    DevPidMonList =
	[{DevNo, Device,
	  spawn_monitor(fun() ->
				flash_device(DevNo, Device, Filename,
					     Opts, Report)
			end)} || {DevNo,Device} <- DeviceList],
    %% wait for all processes to terminate
    flash_wait(DevPidMonList).

flash_wait([{DevNo,Device,{Pid,Mon}}|DevPidMonList]) ->
    receive
	{'DOWN', Mon, process, Pid, normal} ->
	    flash_wait(DevPidMonList);
	{'DOWN', Mon, process, Pid, Error} ->
	    io:format("failed to flash uart ~w (~s) error: ~p\n",
		      [DevNo, Device, Error]),
	    flash_wait(DevPidMonList)
    end;
flash_wait([]) ->
    ok.

report(DevNo, {progress, Written, Total}) when Total > 0 ->
    io:format("~w: ~w%\n", [DevNo, (Written*100) div Total]);
report(DevNo, Event) ->
    io:format("~w: ~p\n", [DevNo, Event]).

%%--------------------------------------------------------------------
%% Flash one device
%%--------------------------------------------------------------------

%% @doc
%%   Number of bytes that will be written for a firmware file,
%%   rounded up to whole segments.
%% @end
-spec firmware_size(string(), integer()) -> {ok, integer()} | {error, term()}.
firmware_size(Filename, Addr) ->
    case elpcisp:load_firmware(Filename, Addr) of
	{ok, AddrLines} ->
	    {ok, lists:sum([segments(byte_size(Data))*?SEGMENT_SIZE ||
			       {_Addr, Data} <- AddrLines])};
	Error ->
	    Error
    end.

segments(Size) ->
    (Size + ?SEGMENT_SIZE - 1) div ?SEGMENT_SIZE.

%% @doc
%%   Flash Filename onto Device, reporting progress through Report.
%%   This mirrors elpcisp:flash_file/3 but with per phase reporting.
%%   Meant to be run in its own process (one per uart).
%% @end
-spec flash_device(devno(), string(), string(), map(), report()) ->
	  ok | {error, term()}.
flash_device(DevNo, Device, Filename, Opts, Report) ->
    #{ baud := Baud, flash_baud := FlashBaud, oscillator := Osc,
       addr := Addr, sync_retry := SyncRetry, sync_tmo := SyncTmo } = Opts,
    SegmentSize = maps:get(segment_size, Opts, ?SEGMENT_SIZE),
    Total = case firmware_size(Filename, Addr) of
		{ok, T} -> T;
		_ -> 0
	    end,
    Report(DevNo, {phase, open}),
    case elpcisp:open(Device, Baud) of
	{ok, U} ->
	    %% elpcisp keeps these in the process dictionary
	    put(control, maps:get(control, Opts, false)),
	    put(control_inv, maps:get(control_inv, Opts, false)),
	    put(control_swap, maps:get(control_swap, Opts, false)),
	    put(written, 0),
	    Cb = fun(_NextAddr) ->
			 N = get(written) + SegmentSize,
			 put(written, N),
			 Report(DevNo, {progress, N, Total})
		 end,
	    try
		step(DevNo, sync, Report,
		     fun() -> elpcisp:sync_osc(U, SyncRetry, SyncTmo,
					       integer_to_list(Osc)) end),
		Report(DevNo, {info, elpcisp:info(U)}),
		step(DevNo, baud, Report,
		     fun() ->
			     case elpcisp:set_baud_rate(U, FlashBaud, 1) of
				 {ok,_} ->
				     uart:setopts(U, [{ibaud,FlashBaud},
						      {obaud,FlashBaud}]);
				 Error -> Error
			     end
		     end),
		step(DevNo, unlock, Report, fun() -> elpcisp:unlock(U) end),
		step(DevNo, write, Report,
		     fun() -> elpcisp:flash_uart(U, Filename, Addr,
						 SegmentSize, Cb) end),
		step(DevNo, go, Report, fun() -> elpcisp:go(U, 0) end),
		Report(DevNo, done),
		ok
	    catch
		throw:{failed, Phase, Reason} ->
		    Report(DevNo, {error, Phase, Reason}),
		    {error, {Phase, Reason}};
		Class:Reason:Stack ->
		    Report(DevNo, {error, write, {Class, Reason}}),
		    io:format("flash ~w (~s) crashed: ~p:~p\n~p\n",
			      [DevNo, Device, Class, Reason, Stack]),
		    {error, {Class, Reason}}
	    after
		uart:close(U)
	    end;
	Error ->
	    Report(DevNo, {error, open, Error}),
	    Error
    end.

step(DevNo, Phase, Report, Fun) ->
    Report(DevNo, {phase, Phase}),
    case Fun() of
	ok -> ok;
	{ok, _} -> ok;
	Error -> throw({failed, Phase, Error})
    end.
