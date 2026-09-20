%%% @author Raspberry Pi OS <erik@grytet>
%%% @copyright (C) 2026, Raspberry Pi OS
%%% @doc
%%%
%%% @end
%%% Created : 19 Sep 2026 by Raspberry Pi OS <erik@grytet>

-module(gillespie).

-export([start/0]).
-export([list_devices/0]).
-export([devices/0]).
-export([flash/0, flash/1]).

-include_lib("kernel/include/file.hrl").

-define(APP, ?MODULE).

start() ->
    application:ensure_all_started(?APP).

%% list devices attached

list_devices() ->
    {ok, List} = application:get_env(?APP, uart_list),
    lists:foreach(
      fun({DevNo, DevFilename}) ->
	      case is_device(DevFilename) of 
		  true ->
		      io:format("~w: ~s OK\n", [DevNo, DevFilename]);
		  false ->
		      io:format("~w: ~s NOT PRESENT\n", [DevNo, DevFilename])
	      end
      end, List).

%% return list of devices present
devices() ->
    {ok, List} = application:get_env(?APP, uart_list),
    List2 = lists:foldl(
	      fun({DevNo, DevFilename}, Acc) ->
		      case filelib:wildcard(DevFilename) of
			  [RealDevFilename] ->
			      case is_device(RealDevFilename) of
				  true -> [{DevNo, RealDevFilename}|Acc];
				  false -> Acc
			      end;
			  _ -> %% warn?
			      Acc
		      end
	      end, [], List),
    {ok, List2}.
    
is_device(Filename) ->
    case file:read_file_info(Filename) of
	{ok, FI} ->
	    FI#file_info.type =:= device;
	{error, enoent} ->
	    false
    end.

flash() ->
    {ok, Filename} = application:get_env(?APP, filename),
    flash(Filename).

flash(Filename) ->
    {ok, DeviceList} = devices(),
    {ok, Baud} = application:get_env(?APP, baud, 3800),
    {ok, FlashBaud} = application:get_env(?APP, flash_baud, 3800),
    {ok, Oscillator} = application:get_env(?APP, oscillator, 12000),
    {ok, Addr} = application:get_env(?APP, addr, 0),
    FlashCb = fun(_) -> ok end,
    Options = #{ baud => Baud,
		 flash_baud => FlashBaud,
		 oscillator => Oscillator,
		 sync_retry => 3,
		 sync_tmo => 2000,
		 control => false,
		 control_inv => false,
		 control_swap => false,
		 addr => Addr,
		 flash_cb => FlashCb
	       },
    DevPidMonList = [{DevNo,Device,
		      spawn_monitor(fun() -> 
					    ok = elpcisp:flash_file(Device, Filename, Options)
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
    

