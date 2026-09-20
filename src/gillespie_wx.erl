%%% @author Tony Rogvall <tony@rogvall.se>
%%% @copyright (C) 2026, Tony Rogvall
%%% @doc
%%%    One page wx GUI for gillespie multi flash.
%%%
%%%    - firmware file selector
%%%    - flash options (saved to the config file)
%%%    - one row per uart: enable, device, chip, status, progress, result
%%%    - flash all / abort / rescan / save
%%%    - log window
%%% @end

-module(gillespie_wx).
-behaviour(wx_object).

-export([start/0, start_link/0]).
-export([init/1, handle_event/2, handle_info/2, handle_call/3,
	 handle_cast/2, terminate/2, code_change/3]).

-include_lib("wx/include/wx.hrl").

-define(TITLE, "Gillespie - LPC multi flash").
-define(BAUD_CHOICES, ["9600","19200","38400","57600","115200","230400"]).

-define(GREEN, {0,128,0}).
-define(RED,   {192,0,0}).
-define(GREY,  {128,128,128}).
-define(BLUE,  {0,64,192}).

-record(row,
	{
	 no        :: integer(),
	 pattern   :: string(),
	 device    :: string() | undefined,
	 enabled   :: boolean(),
	 check     :: wx:wx_object(),
	 dev_text  :: wx:wx_object(),
	 chip_text :: wx:wx_object(),
	 status    :: wx:wx_object(),
	 gauge     :: wx:wx_object(),
	 result    :: wx:wx_object(),
	 outcome   :: undefined | ok | error | aborted
	}).

-record(state,
	{
	 frame,
	 panel,
	 file_text,
	 size_text,
	 baud,
	 flash_baud,
	 osc,
	 addr,
	 sync_retry,
	 sync_tmo,
	 control,
	 control_inv,
	 control_swap,
	 rows = [] :: [#row{}],
	 scan_btn,
	 flash_btn,
	 abort_btn,
	 save_btn,
	 summary,
	 log,
	 workers = #{} :: #{integer() => {pid(), reference()}},
	 started,
	 dref :: reference()
	}).

start() ->
    wx_object:start({local, ?MODULE}, ?MODULE, [], []).

start_link() ->
    wx_object:start_link({local, ?MODULE}, ?MODULE, [], []).

%%--------------------------------------------------------------------
%% init
%%--------------------------------------------------------------------

init([]) ->
    {ok,DRef} = fnotify:watch("/dev"),
    wx:new(),
    Config = gillespie:config(),
    Frame = wxFrame:new(wx:null(), ?wxID_ANY, ?TITLE),
    Panel = wxPanel:new(Frame),
    Top = wxBoxSizer:new(?wxVERTICAL),

    %% ---- Firmware -------------------------------------------------
    FwBox = wxStaticBoxSizer:new(?wxHORIZONTAL, Panel, [{label, "Firmware"}]),
    FileText = wxTextCtrl:new(Panel, ?wxID_ANY,
			      [{value, maps:get(filename, Config)}]),
    Browse = wxButton:new(Panel, ?wxID_ANY, [{label, "Browse..."}]),
    SizeText = wxStaticText:new(Panel, ?wxID_ANY, ""),
    wxSizer:add(FwBox, FileText, [{proportion,1},{flag,?wxEXPAND bor ?wxALL},{border,4}]),
    wxSizer:add(FwBox, Browse, [{flag,?wxALL},{border,4}]),
    wxSizer:add(FwBox, SizeText, [{flag,?wxALIGN_CENTER_VERTICAL bor ?wxALL},{border,4}]),
    wxSizer:add(Top, FwBox, [{flag,?wxEXPAND bor ?wxALL},{border,6}]),

    %% ---- Options --------------------------------------------------
    OptBox = wxStaticBoxSizer:new(?wxVERTICAL, Panel, [{label, "Options"}]),
    Grid = wxFlexGridSizer:new(0, 8, 4, 8),
    Baud = combo(Panel, Grid, "Baud", maps:get(baud, Config)),
    FlashBaud = combo(Panel, Grid, "Flash baud", maps:get(flash_baud, Config)),
    Osc = entry(Panel, Grid, "Oscillator (kHz)",
		integer_to_list(maps:get(oscillator, Config))),
    Addr = entry(Panel, Grid, "Address",
		 io_lib:format("0x~.16B", [maps:get(addr, Config)])),
    SyncRetry = spin(Panel, Grid, "Sync retry", 1, 100,
		     maps:get(sync_retry, Config)),
    SyncTmo = spin(Panel, Grid, "Sync timeout (ms)", 100, 60000,
		   maps:get(sync_tmo, Config)),
    wxSizer:add(OptBox, Grid, [{flag,?wxALL},{border,4}]),
    CtlRow = wxBoxSizer:new(?wxHORIZONTAL),
    Control = checkbox(Panel, CtlRow, "Control (DTR/RTS reset)",
		       maps:get(control, Config)),
    ControlInv = checkbox(Panel, CtlRow, "Control invert",
			  maps:get(control_inv, Config)),
    ControlSwap = checkbox(Panel, CtlRow, "Control swap",
			   maps:get(control_swap, Config)),
    wxSizer:add(OptBox, CtlRow, [{flag,?wxALL},{border,4}]),
    wxSizer:add(Top, OptBox, [{flag,?wxEXPAND bor ?wxALL},{border,6}]),

    %% ---- Uarts ----------------------------------------------------
    UartBox = wxStaticBoxSizer:new(?wxVERTICAL, Panel, [{label, "UARTs"}]),
    UGrid = wxFlexGridSizer:new(0, 7, 3, 10),
    wxFlexGridSizer:addGrowableCol(UGrid, 2),
    wxFlexGridSizer:addGrowableCol(UGrid, 6),
    lists:foreach(
      fun(Label) ->
	      T = wxStaticText:new(Panel, ?wxID_ANY, Label),
	      wxStaticText:setFont(T, bold_font(Panel)),
	      wxSizer:add(UGrid, T, [{flag, ?wxALIGN_CENTER_VERTICAL}])
      end, ["Use", "#", "Device", "Chip", "Status", "Progress", "Result"]),
    Rows = [make_row(Panel, UGrid, Scan) || Scan <- gillespie:scan()],
    wxSizer:add(UartBox, UGrid, [{flag,?wxEXPAND bor ?wxALL},{border,4}]),
    wxSizer:add(Top, UartBox, [{flag,?wxEXPAND bor ?wxALL},{border,6}]),

    %% ---- Buttons --------------------------------------------------
    BtnRow = wxBoxSizer:new(?wxHORIZONTAL),
    ScanBtn = wxButton:new(Panel, ?wxID_ANY, [{label, "Rescan"}]),
    FlashBtn = wxButton:new(Panel, ?wxID_ANY, [{label, "Flash all"}]),
    AbortBtn = wxButton:new(Panel, ?wxID_ANY, [{label, "Abort"}]),
    SaveBtn = wxButton:new(Panel, ?wxID_ANY, [{label, "Save config"}]),
    wxButton:disable(AbortBtn),
    wxButton:setFont(FlashBtn, bold_font(Panel)),
    Summary = wxFrame:createStatusBar(Frame),
    wxSizer:add(BtnRow, ScanBtn, [{flag,?wxALL},{border,4}]),
    wxSizer:add(BtnRow, FlashBtn, [{flag,?wxALL},{border,4}]),
    wxSizer:add(BtnRow, AbortBtn, [{flag,?wxALL},{border,4}]),
    wxSizer:addStretchSpacer(BtnRow),
    wxSizer:add(BtnRow, SaveBtn, [{flag,?wxALL},{border,4}]),
    wxSizer:add(Top, BtnRow, [{flag,?wxEXPAND bor ?wxLEFT bor ?wxRIGHT},{border,6}]),

    %% ---- Log ------------------------------------------------------
    Log = wxTextCtrl:new(Panel, ?wxID_ANY,
			 [{style, ?wxTE_MULTILINE bor ?wxTE_READONLY bor
			       ?wxTE_RICH2 bor ?wxHSCROLL},
			  {size, {-1, 160}}]),
    wxTextCtrl:setFont(Log, mono_font()),
    wxSizer:add(Top, Log, [{proportion,1},{flag,?wxEXPAND bor ?wxALL},{border,6}]),

    wxPanel:setSizer(Panel, Top),
    wxSizer:setSizeHints(Top, Frame),
    wxFrame:setMinSize(Frame, wxFrame:getSize(Frame)),
    {W, H} = wxFrame:getSize(Frame),
    wxFrame:setSize(Frame, {max(W, 1000), H + 100}),

    %% ---- Events ---------------------------------------------------
    wxFrame:connect(Frame, close_window),
    wxButton:connect(Browse, command_button_clicked, [{userData, browse}]),
    wxButton:connect(ScanBtn, command_button_clicked, [{userData, scan}]),
    wxButton:connect(FlashBtn, command_button_clicked, [{userData, flash}]),
    wxButton:connect(AbortBtn, command_button_clicked, [{userData, abort}]),
    wxButton:connect(SaveBtn, command_button_clicked, [{userData, save}]),
    wxTextCtrl:connect(FileText, command_text_updated, [{userData, file}]),
    lists:foreach(
      fun(#row{no=No, check=Check}) ->
	      wxCheckBox:connect(Check, command_checkbox_clicked,
				 [{userData, {enable, No}}])
      end, Rows),

    wxFrame:show(Frame),

    State0 = #state{ frame = Frame, panel = Panel,
		     file_text = FileText, size_text = SizeText,
		     baud = Baud, flash_baud = FlashBaud, osc = Osc,
		     addr = Addr, sync_retry = SyncRetry, sync_tmo = SyncTmo,
		     control = Control, control_inv = ControlInv,
		     control_swap = ControlSwap,
		     rows = Rows,
		     scan_btn = ScanBtn, flash_btn = FlashBtn,
		     abort_btn = AbortBtn, save_btn = SaveBtn,
		     summary = Summary, log = Log, dref = DRef },
    State1 = update_file_size(State0),
    State2 = update_summary(State1),
    log(State2, "config file: ~s", [gillespie:config_file()]),
    {Frame, State2}.

%%--------------------------------------------------------------------
%% widget helpers
%%--------------------------------------------------------------------

label(Panel, Sizer, Text) ->
    T = wxStaticText:new(Panel, ?wxID_ANY, Text),
    wxSizer:add(Sizer, T, [{flag, ?wxALIGN_CENTER_VERTICAL}]),
    T.

combo(Panel, Sizer, Label, Value) ->
    label(Panel, Sizer, Label),
    C = wxComboBox:new(Panel, ?wxID_ANY,
		       [{value, integer_to_list(Value)},
			{choices, ?BAUD_CHOICES},
			{style, ?wxCB_DROPDOWN},
			{size, {110, -1}}]),
    wxSizer:add(Sizer, C, [{flag, ?wxALIGN_CENTER_VERTICAL}]),
    C.

entry(Panel, Sizer, Label, Value) ->
    label(Panel, Sizer, Label),
    E = wxTextCtrl:new(Panel, ?wxID_ANY,
		       [{value, lists:flatten(Value)}, {size, {110, -1}}]),
    wxSizer:add(Sizer, E, [{flag, ?wxALIGN_CENTER_VERTICAL}]),
    E.

spin(Panel, Sizer, Label, Min, Max, Value) ->
    label(Panel, Sizer, Label),
    S = wxSpinCtrl:new(Panel, [{min, Min}, {max, Max}, {initial, Value},
			       {size, {110, -1}}]),
    wxSizer:add(Sizer, S, [{flag, ?wxALIGN_CENTER_VERTICAL}]),
    S.

checkbox(Panel, Sizer, Label, Value) ->
    C = wxCheckBox:new(Panel, ?wxID_ANY, Label),
    wxCheckBox:setValue(C, Value),
    wxSizer:add(Sizer, C, [{flag, ?wxALL}, {border, 4}]),
    C.

bold_font(Panel) ->
    F = wxWindow:getFont(Panel),
    wxFont:setWeight(F, ?wxFONTWEIGHT_BOLD),
    F.

mono_font() ->
    wxFont:new(9, ?wxFONTFAMILY_TELETYPE, ?wxFONTSTYLE_NORMAL,
	       ?wxFONTWEIGHT_NORMAL).

make_row(Panel, Sizer, {No, Pattern, Enabled, Device}) ->
    Check = wxCheckBox:new(Panel, ?wxID_ANY, ""),
    wxCheckBox:setValue(Check, Enabled),
    NoText = wxStaticText:new(Panel, ?wxID_ANY, integer_to_list(No)),
    DevText = wxStaticText:new(Panel, ?wxID_ANY, "",
			       [{size, {180,-1}}]),
    ChipText = wxStaticText:new(Panel, ?wxID_ANY, "", [{size, {90,-1}}]),
    Status = wxStaticText:new(Panel, ?wxID_ANY, "", [{size, {100,-1}}]),
    Gauge = wxGauge:new(Panel, ?wxID_ANY, 100,
			[{size, {180, -1}}, {style, ?wxGA_HORIZONTAL}]),
    Result = wxStaticText:new(Panel, ?wxID_ANY, "", [{size, {220,-1}}]),
    Flag = [{flag, ?wxALIGN_CENTER_VERTICAL}],
    wxSizer:add(Sizer, Check, Flag),
    wxSizer:add(Sizer, NoText, Flag),
    wxSizer:add(Sizer, DevText, [{flag, ?wxALIGN_CENTER_VERTICAL bor ?wxEXPAND}]),
    wxSizer:add(Sizer, ChipText, Flag),
    wxSizer:add(Sizer, Status, Flag),
    wxSizer:add(Sizer, Gauge, Flag),
    wxSizer:add(Sizer, Result, [{flag, ?wxALIGN_CENTER_VERTICAL bor ?wxEXPAND}]),
    Row = #row{ no = No, pattern = Pattern, device = Device,
		enabled = Enabled, check = Check, dev_text = DevText,
		chip_text = ChipText, status = Status, gauge = Gauge,
		result = Result },
    update_row_device(Row).

%% show device presence
update_row_device(Row = #row{pattern=Pattern, device=Device,
			     dev_text=DevText, status=Status}) ->
    case Device of
	undefined ->
	    wxStaticText:setLabel(DevText, filename:basename(Pattern)),
	    wxStaticText:setForegroundColour(DevText, ?GREY),
	    set_text(Status, "disconnected", ?GREY);
	_ ->
	    wxStaticText:setLabel(DevText, Device),
	    wxStaticText:setForegroundColour(DevText, {0,0,0}),
	    set_text(Status, "connected", ?GREEN)
    end,
    wxStaticText:setToolTip(DevText, Pattern),
    Row.

set_text(T, Text, Colour) ->
    wxStaticText:setForegroundColour(T, Colour),
    wxStaticText:setLabel(T, lists:flatten(Text)).

%%--------------------------------------------------------------------
%% events
%%--------------------------------------------------------------------

handle_event(#wx{event=#wxClose{}}, State) ->
    {stop, normal, State};

handle_event(#wx{userData=browse, event=#wxCommand{type=command_button_clicked}},
	     State) ->
    Current = wxTextCtrl:getValue(State#state.file_text),
    Dir = case filename:dirname(Current) of
	      "." -> {ok, Cwd} = file:get_cwd(), Cwd;
	      D -> D
	  end,
    Dlg = wxFileDialog:new(State#state.frame,
			   [{message, "Select firmware"},
			    {defaultDir, Dir},
			    {defaultFile, filename:basename(Current)},
			    {wildCard, "Firmware (*.bin;*.ihex)|*.bin;*.ihex|"
			     "All files (*)|*"},
			    {style, ?wxFD_OPEN bor ?wxFD_FILE_MUST_EXIST}]),
    State1 =
	case wxFileDialog:showModal(Dlg) of
	    ?wxID_OK ->
		Path = wxFileDialog:getPath(Dlg),
		wxTextCtrl:changeValue(State#state.file_text, Path),
		log(State, "firmware: ~s", [Path]),
		update_file_size(State);
	    _ ->
		State
	end,
    wxFileDialog:destroy(Dlg),
    {noreply, State1};

handle_event(#wx{userData=file, event=#wxCommand{type=command_text_updated}},
	     State) ->
    {noreply, update_file_size(State)};

handle_event(#wx{userData=scan, event=#wxCommand{type=command_button_clicked}},
	     State) ->
    {noreply, rescan(State)};

handle_event(#wx{userData={enable,No}, event=#wxCommand{type=command_checkbox_clicked,
							commandInt=Int}},
	     State) ->
    Enabled = Int =/= 0,
    Rows = [if R#row.no =:= No -> R#row{enabled = Enabled}; true -> R end
	    || R <- State#state.rows],
    {noreply, update_summary(State#state{rows = Rows})};

handle_event(#wx{userData=save, event=#wxCommand{type=command_button_clicked}},
	     State) ->
    case read_config(State) of
	{ok, Config} ->
	    case gillespie:save_config(Config) of
		{ok, File} ->
		    log(State, "config saved to ~s", [File]);
		{error, Reason} ->
		    log(State, "config save FAILED: ~p", [Reason]),
		    error_dialog(State, io_lib:format("Save failed: ~p", [Reason]))
	    end;
	{error, Text} ->
	    error_dialog(State, Text)
    end,
    {noreply, State};

handle_event(#wx{userData=flash, event=#wxCommand{type=command_button_clicked}},
	     State) when map_size(State#state.workers) =:= 0 ->
    case read_config(State) of
	{ok, Config} ->
	    {noreply, start_flash(State, Config)};
	{error, Text} ->
	    error_dialog(State, Text),
	    {noreply, State}
    end;

handle_event(#wx{userData=abort, event=#wxCommand{type=command_button_clicked}},
	     State) ->
    log(State, "abort!", []),
    maps:foreach(fun(_No, {Pid, _Mon}) -> exit(Pid, kill) end,
		 State#state.workers),
    {noreply, State};

handle_event(_Event, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% worker messages
%%--------------------------------------------------------------------

handle_info({gillespie, No, Event}, State) ->
    {noreply, row_event(No, Event, State)};

handle_info(rescan, State) ->
    flush(rescan),
    {noreply, rescan(State)};

handle_info({'DOWN', Mon, process, Pid, Reason}, State) ->
    Workers = maps:filter(fun(_No, {P, M}) -> {P, M} =/= {Pid, Mon} end,
			  State#state.workers),
    State1 =
	case [No || {No, {P, M}} <- maps:to_list(State#state.workers),
		    {P, M} =:= {Pid, Mon}] of
	    [No] when Reason =:= killed ->
		row_event(No, {error, aborted, killed}, State);
	    [No] when Reason =/= normal ->
		row_event(No, {error, crash, Reason}, State);
	    _ ->
		State
	end,
    State2 = State1#state{workers = Workers},
    case map_size(Workers) of
	0 -> {noreply, flash_finished(State2)};
	_ -> {noreply, update_summary(State2)}
    end;

handle_info(_F={fevent,Ref,[create],_Path,_Name="tty"++_}, State) 
  when Ref =:= State#state.dref ->
    %% io:format("CREATE path=~s, name=~s\n", [_Path, _Name]),
    SELF = self(),
    %% add a small delay to allow operting system to settle
    spawn(fun() -> timer:sleep(500), SELF ! rescan end),
    {noreply, State};
handle_info(_F={fevent,Ref,[delete],_Path,_Name="tty"++_}, State) 
  when Ref =:= State#state.dref ->
    %% io:format("DELETE path=~s, name=~s\n", [_Path, _Name]),
    SELF = self(),
    %% add a small delay to allow operting system to settle
    spawn(fun() -> timer:sleep(500), SELF ! rescan end),
    {noreply, State};

handle_info(_F={fevent,Ref,_Ev,_Path,_Name}, State) 
  when Ref =:= State#state.dref ->
    %% io:format("IGNORE FEVENT ~p path=~s, name=~s\n", [_Ev, _Path, _Name]),
    {noreply, State};

    

handle_info(_Info, State) ->
    {noreply, State}.

handle_call(_Req, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, State) ->
    maps:foreach(fun(_No, {Pid, _Mon}) -> exit(Pid, kill) end,
		 State#state.workers),
    wx:destroy(),
    ok.

%% flush rescan events

flush(Msg) ->
    receive
	Msg -> flush(Msg)
    after 500 ->
	    ok
    end.

%%--------------------------------------------------------------------
%% flash control
%%--------------------------------------------------------------------

start_flash(State, Config) ->
    #{ filename := Filename, addr := Addr } = Config,
    Targets = [R || R = #row{enabled=true, device=Dev} <- State#state.rows,
		    Dev =/= undefined],
    case gillespie:firmware_size(Filename, Addr) of
	{error, Reason} ->
	    error_dialog(State, io_lib:format("Can not load ~s: ~p",
					      [Filename, Reason])),
	    State;
	{ok, _Size} when Targets =:= [] ->
	    error_dialog(State, "No enabled and connected devices"),
	    State;
	{ok, Size} ->
	    Opts = gillespie:options(Config),
	    Self = self(),
	    Report = fun(No, Event) -> Self ! {gillespie, No, Event} end,
	    log(State, "flash ~s (~w bytes) to ~w device(s)",
		[Filename, Size, length(Targets)]),
	    Workers =
		maps:from_list(
		  [{No, spawn_monitor(
			  fun() ->
				  gillespie:flash_device(No, Dev, Filename,
							 Opts, Report)
			  end)} ||
		      #row{no=No, device=Dev} <- Targets]),
	    Rows = [reset_row(R, lists:member(R, Targets)) ||
		       R <- State#state.rows],
	    set_busy(State, true),
	    update_summary(State#state{workers = Workers, rows = Rows,
				       started = erlang:monotonic_time()})
    end.

reset_row(Row = #row{gauge=Gauge, result=Result, chip_text=Chip}, IsTarget) ->
    wxGauge:setValue(Gauge, 0),
    wxStaticText:setLabel(Chip, ""),
    if IsTarget ->
	    set_text(Result, "waiting", ?GREY);
       true ->
	    set_text(Result, "", ?GREY)
    end,
    Row#row{outcome = undefined}.

flash_finished(State) ->
    Rows = State#state.rows,
    Ok = length([R || R = #row{outcome=ok} <- Rows]),
    Err = length([R || R = #row{outcome=Out} <- Rows,
		       Out =:= error orelse Out =:= aborted]),
    Secs = case State#state.started of
	       undefined -> 0;
	       T0 -> erlang:convert_time_unit(erlang:monotonic_time() - T0,
					      native, millisecond) / 1000
	   end,
    log(State, "done: ~w ok, ~w failed, ~.1f s", [Ok, Err, Secs]),
    set_busy(State, false),
    update_summary(State).

set_busy(State, Busy) ->
    Enable = fun(W, true) -> wxWindow:enable(W);
		(W, false) -> wxWindow:disable(W)
	     end,
    Enable(State#state.abort_btn, Busy),
    Enable(State#state.flash_btn, not Busy),
    Enable(State#state.scan_btn, not Busy),
    Enable(State#state.save_btn, not Busy),
    lists:foreach(fun(#row{check=C}) -> Enable(C, not Busy) end,
		  State#state.rows),
    ok.

rescan(State) ->
    Scan = gillespie:scan(),
    Rows = [case lists:keyfind(R#row.no, 1, Scan) of
		{_No, Pattern, _Enabled, Device} ->
		    update_row_device(R#row{pattern = Pattern,
					    device = Device});
		false ->
		    R
	    end || R <- State#state.rows],
    N = length([R || R = #row{device=D} <- Rows, D =/= undefined]),
    log(State, "rescan: ~w of ~w devices connected", [N, length(Rows)]),
    update_summary(State#state{rows = Rows}).

%%--------------------------------------------------------------------
%% row updates from workers
%%--------------------------------------------------------------------

row_event(No, Event, State) ->
    case lists:keyfind(No, #row.no, State#state.rows) of
	false ->
	    State;
	Row ->
	    Row1 = apply_event(Event, Row, State),
	    Rows = lists:keyreplace(No, #row.no, State#state.rows, Row1),
	    State1 = State#state{rows = Rows},
	    case Event of
		{progress, _, _} -> State1;
		_ -> update_summary(State1)
	    end
    end.

apply_event({phase, Phase}, Row, _State) ->
    set_text(Row#row.result, phase_text(Phase), ?BLUE),
    Row;
apply_event({info, Info}, Row, State) ->
    Product = case proplists:get_value(product, Info) of
		  undefined -> "?";
		  P -> P
	      end,
    Vsn = case proplists:get_value(version, Info) of
	      {Major, Minor} -> io_lib:format(" boot ~w.~w", [Major, Minor]);
	      _ -> ""
	  end,
    wxStaticText:setLabel(Row#row.chip_text, Product),
    log(State, "#~w ~s: ~s~s id=~p",
	[Row#row.no, Row#row.device, Product, Vsn,
	 proplists:get_value(id, Info)]),
    Row;
apply_event({progress, Written, Total}, Row, _State) when Total > 0 ->
    Pct = min(100, (Written * 100) div Total),
    wxGauge:setValue(Row#row.gauge, Pct),
    set_text(Row#row.result, io_lib:format("writing ~w%", [Pct]), ?BLUE),
    Row;
apply_event({progress, _Written, _Total}, Row, _State) ->
    wxGauge:pulse(Row#row.gauge),
    Row;
apply_event(done, Row, State) ->
    wxGauge:setValue(Row#row.gauge, 100),
    set_text(Row#row.result, "OK", ?GREEN),
    log(State, "#~w ~s: OK", [Row#row.no, Row#row.device]),
    Row#row{outcome = ok};
apply_event({error, _Phase, _Reason}, Row = #row{outcome=Out}, _State)
  when Out =/= undefined ->
    %% already reported (e.g. error followed by DOWN)
    Row;
apply_event({error, aborted, _Reason}, Row, State) ->
    set_text(Row#row.result, "aborted", ?RED),
    log(State, "#~w ~s: aborted", [Row#row.no, Row#row.device]),
    Row#row{outcome = aborted};
apply_event({error, Phase, Reason}, Row, State) ->
    Text = io_lib:format("~s failed: ~s", [Phase, short(Reason)]),
    set_text(Row#row.result, Text, ?RED),
    log(State, "#~w ~s: ~s failed: ~p",
	[Row#row.no, Row#row.device, Phase, Reason]),
    Row#row{outcome = error}.

phase_text(open) -> "opening";
phase_text(sync) -> "syncing";
phase_text(baud) -> "set baud";
phase_text(unlock) -> "unlocking";
phase_text(write) -> "erasing";
phase_text(go) -> "starting";
phase_text(Other) -> atom_to_list(Other).

short(Reason) ->
    S = lists:flatten(io_lib:format("~p", [Reason])),
    case length(S) > 40 of
	true -> string:slice(S, 0, 37) ++ "...";
	false -> S
    end.

%%--------------------------------------------------------------------
%% summary / file size / log
%%--------------------------------------------------------------------

update_summary(State = #state{rows=Rows, summary=Summary}) ->
    Connected = length([R || R = #row{device=D} <- Rows, D =/= undefined]),
    Enabled = length([R || R = #row{enabled=true, device=D} <- Rows,
			   D =/= undefined]),
    Ok = length([R || R = #row{outcome=ok} <- Rows]),
    Failed = length([R || R = #row{outcome=O} <- Rows,
			  O =:= error orelse O =:= aborted]),
    Running = map_size(State#state.workers),
    Text = io_lib:format("~w of ~w connected, ~w selected  |  ~w running, ~w ok, ~w failed",
			 [Connected, length(Rows), Enabled, Running, Ok, Failed]),
    wxStatusBar:setStatusText(Summary, lists:flatten(Text)),
    State.

update_file_size(State = #state{file_text=FileText, size_text=SizeText}) ->
    Filename = wxTextCtrl:getValue(FileText),
    Addr = case parse_int(wxTextCtrl:getValue(State#state.addr)) of
	       {ok, A} -> A;
	       _ -> 0
	   end,
    case filelib:is_regular(Filename) of
	false ->
	    set_text(SizeText, "file not found", ?RED);
	true ->
	    case gillespie:firmware_size(Filename, Addr) of
		{ok, Size} ->
		    set_text(SizeText,
			     io_lib:format("~w bytes (~.1f kB)",
					   [Size, Size/1024]), ?GREEN);
		{error, Reason} ->
		    set_text(SizeText, short(Reason), ?RED)
	    end
    end,
    wxSizer:layout(wxWindow:getSizer(State#state.panel)),
    State.

log(#state{log=Log}, Fmt, Args) ->
    {_, {H,M,S}} = calendar:local_time(),
    Line = io_lib:format("~2..0w:~2..0w:~2..0w " ++ Fmt ++ "\n",
			 [H,M,S|Args]),
    wxTextCtrl:appendText(Log, lists:flatten(Line)),
    ok.

error_dialog(State, Text) ->
    Dlg = wxMessageDialog:new(State#state.frame, lists:flatten(Text),
			      [{caption, "Gillespie"},
			       {style, ?wxOK bor ?wxICON_ERROR}]),
    wxMessageDialog:showModal(Dlg),
    wxMessageDialog:destroy(Dlg).

%%--------------------------------------------------------------------
%% read the config from widgets
%%--------------------------------------------------------------------

read_config(State) ->
    try
	Config0 = gillespie:config(),
	UartList = [{No, Pattern, Enabled} ||
		       #row{no=No, pattern=Pattern, enabled=Enabled}
			   <- State#state.rows],
	Config0#{
		 uart_list => UartList,
		 filename => wxTextCtrl:getValue(State#state.file_text),
		 baud => int(wxComboBox:getValue(State#state.baud), "baud"),
		 flash_baud => int(wxComboBox:getValue(State#state.flash_baud),
				   "flash baud"),
		 oscillator => int(wxTextCtrl:getValue(State#state.osc),
				   "oscillator"),
		 addr => int(wxTextCtrl:getValue(State#state.addr), "address"),
		 sync_retry => wxSpinCtrl:getValue(State#state.sync_retry),
		 sync_tmo => wxSpinCtrl:getValue(State#state.sync_tmo),
		 control => wxCheckBox:getValue(State#state.control),
		 control_inv => wxCheckBox:getValue(State#state.control_inv),
		 control_swap => wxCheckBox:getValue(State#state.control_swap)
		}
    of
	Config -> {ok, Config}
    catch
	throw:{bad_value, What, Value} ->
	    {error, io_lib:format("Bad value for ~s: ~p", [What, Value])}
    end.

int(String, What) ->
    case parse_int(String) of
	{ok, Int} -> Int;
	error -> throw({bad_value, What, String})
    end.

%% accept decimal, 0x hex and 16#hex
parse_int(String) ->
    S = string:trim(String),
    try
	case S of
	    "0x" ++ Hex -> {ok, list_to_integer(Hex, 16)};
	    "0X" ++ Hex -> {ok, list_to_integer(Hex, 16)};
	    "16#" ++ Hex -> {ok, list_to_integer(Hex, 16)};
	    _ -> {ok, list_to_integer(S)}
	end
    catch
	error:badarg -> error
    end.
