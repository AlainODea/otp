%%
%% %CopyrightBegin%
%% 
%% Copyright Ericsson AB 2008-2009. All Rights Reserved.
%% 
%% The contents of this file are subject to the Erlang Public License,
%% Version 1.1, (the "License"); you may not use this file except in
%% compliance with the License. You should have received a copy of the
%% Erlang Public License along with this software. If not, it can be
%% retrieved online at http://www.erlang.org/.
%% 
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and limitations
%% under the License.
%% 
%% %CopyrightEnd%
%%

%%
-module(dbg_wx_view).

%% External exports
-export([start/2]).

-record(state, {gs,                % term() Graphics system id
		win,               % term() Attach process window data
		coords,            % {X,Y} Mouse point position
		mod                % atom() Module
	       }).

%%====================================================================
%% External exports
%%====================================================================

%%--------------------------------------------------------------------
%% start(GS, Mod)
%%   Mod = atom()
%%--------------------------------------------------------------------
start(GS, Mod) ->
    Title = "View Module " ++ atom_to_list(Mod),
    case dbg_wx_winman:is_started(Title) of
	true -> ignore;
	false -> 
	    Env = wx:get_env(),
	    spawn_link(fun () -> init(GS, Env, Mod, Title) end)
    end.


%%====================================================================
%% Main loop and message handling
%%====================================================================

init(GS, Env, Mod, Title) ->
    wx:set_env(Env),
    %% Subscribe to messages from the interpreter
    int:subscribe(),

    %% Create attach process window
    Win1 = dbg_wx_trace_win:create_win(GS, Title, ['Code Area', 'Search Area'], menus()),
    Window = dbg_wx_trace_win:get_window(Win1),
    dbg_wx_winman:insert(Title, Window),

    Win2 = gui_load_module(Win1, Mod),
    Win3 =
	lists:foldl(fun(Break, Win) ->
			    dbg_wx_trace_win:add_break(Win, 'Break', Break)
		    end,
		    Win2,
		    int:all_breaks(Mod)),
    
    try loop(#state{gs=GS, win=Win3, coords={0,0}, mod=Mod}) 
    catch _E:normal ->
	    exit(normal);
	  _E:_R ->
	    io:format("~p:~p ~p~n",[?MODULE,_E,_R]),
	    exit(_R)
    end.

loop(State) ->
    receive

	%% From the GUI main window
	GuiEvent when element(1, GuiEvent) =:= wx ->
	    Cmd = wx:batch(fun() -> 
				   dbg_wx_trace_win:handle_event(GuiEvent, State#state.win)
			   end),
	    State2 = gui_cmd(Cmd, State),
	    loop(State2);

	%% From the GUI help windows
	{gui, Cmd} ->
	    State2 = gui_cmd(Cmd, State),
	    loop(State2);

	%% From the interpreter
	{int, Cmd} ->
	    State2 = int_cmd(Cmd, State),
	    loop(State2);

	%% From the dbg_wx_winman process (Debugger window manager)
	{dbg_ui_winman, update_windows_menu, Data} ->
	    Window = dbg_wx_trace_win:get_window(State#state.win),
	    dbg_wx_winman:update_windows_menu(Window,Data),
	    loop(State);
	{dbg_ui_winman, destroy} ->
	    dbg_wx_trace_win:stop(State#state.win),
	    exit(stop);

	%% Help window termination -- ignore
	{'EXIT', _Pid, _Reason} ->
	    loop(State)
    end.

%%--Commands from the GUI---------------------------------------------

gui_cmd(ignore, State) ->
    State;
gui_cmd({win, Win}, State) ->
    State#state{win=Win};
gui_cmd(stopped, _State) ->
    exit(normal);
gui_cmd({coords, Coords}, State) ->
    State#state{coords=Coords};

gui_cmd({shortcut, Key}, State) ->
    case shortcut(Key) of
	false -> State;
	Cmd -> gui_cmd(Cmd, State)
    end;

%% File menu
gui_cmd('Close', State) ->
    dbg_wx_trace_win:stop(State#state.win),
    gui_cmd(stopped, State);

%% Edit menu
gui_cmd('Go To Line', State) ->
    %% Will result in message handled below: {gui, {gotoline, Line}}
    Win = dbg_wx_trace_win:helpwin(gotoline, State#state.win),
    State#state{win=Win};
gui_cmd({gotoline, Line}, State) ->
    Win = dbg_wx_trace_win:select_line(State#state.win, Line),
    State#state{win=Win};
gui_cmd('Search', State) ->
    Win = dbg_wx_trace_win:helpwin(search, State#state.win),
    State#state{win=Win};

%% Break menu
gui_cmd('Line Break...', State) ->
    add_break(State#state.gs, State#state.coords, line,
	      State#state.mod,
	      dbg_wx_trace_win:selected_line(State#state.win)),
    State;
gui_cmd('Conditional Break...', State) ->
    add_break(State#state.gs, State#state.coords, conditional,
	      State#state.mod,
	      dbg_wx_trace_win:selected_line(State#state.win)),
    State;
gui_cmd('Function Break...', State) ->
    add_break(State#state.gs, State#state.coords, function,
	      State#state.mod, undefined),
    State;
gui_cmd('Enable All', State) ->
    Breaks = int:all_breaks(),
    ThisMod = State#state.mod,
    lists:foreach(fun ({{Mod, Line}, _Options}) when Mod =:= ThisMod ->
			  int:enable_break(Mod, Line);
		      (_Break) ->
			  ignore
		  end,
		  Breaks),
    State;
gui_cmd('Disable All', State) ->
    Breaks = int:all_breaks(),
    ThisMod = State#state.mod,
    lists:foreach(fun ({{Mod, Line}, _Options}) when Mod =:= ThisMod ->
			  int:disable_break(Mod, Line);
		      (_Break) ->
			  ignore
		  end,
		  Breaks),
    State;
gui_cmd('Delete All', State) ->
    int:no_break(State#state.mod),
    State;
gui_cmd({break, {Mod, Line}, What}, State) ->
    case What of
	add -> int:break(Mod, Line);
	delete -> int:delete_break(Mod, Line);
	{status, inactive} -> int:disable_break(Mod, Line);
	{status, active} -> int:enable_break(Mod, Line);
	{trigger, Action} -> int:action_at_break(Mod, Line, Action)
    end,
    State;

%% Help menu
gui_cmd('Debugger', State) ->
    Window = dbg_wx_trace_win:get_window(State#state.win),
    HelpFile = filename:join([code:lib_dir(debugger),
			      "doc", "html", "part_frame.html"]),
    dbg_wx_win:open_help(Window, HelpFile),
    State.

add_break(GS, Coords, Type, undefined, _Line) ->
    dbg_wx_break:start(GS, Coords, Type);
add_break(GS, Coords, Type, Mod, undefined) ->
    dbg_wx_break:start(GS, Coords, Type, Mod);
add_break(GS, Coords, Type, Mod, Line) ->
    dbg_wx_break:start(GS, Coords, Type, Mod, Line).

%%--Commands from the interpreter-------------------------------------

int_cmd({new_break, {{Mod,_Line},_Options}=Break},
	#state{mod = Mod, win = Win}=State) ->
    State#state{win = dbg_wx_trace_win:add_break(Win, 'Break', Break)};
int_cmd({delete_break, {Mod,_Line}=Point},
	#state{mod = Mod, win = Win}=State) ->
    State#state{win = dbg_wx_trace_win:delete_break(Win, Point)};
int_cmd({break_options, {{Mod,_Line},_Options}=Break},
	#state{mod = Mod, win = Win}=State) ->
    State#state{win = dbg_wx_trace_win:update_break(Win, Break)};
int_cmd(no_break, #state{win = Win}=State) ->
    State#state{win = dbg_wx_trace_win:clear_breaks(Win)};
int_cmd({no_break, _Mod}, #state{win = Win}=State) ->
    State#state{win = dbg_wx_trace_win:clear_breaks(Win)};
int_cmd(_, State) ->
    State.


%%====================================================================
%% GUI auxiliary functions
%%====================================================================

menus() ->
    [{'File', [{'Close', 0}]},
     {'Edit', [{'Go To Line', 0},
	       {'Search', 0}]},
     {'Break', [{'Line Break...', 5},
		{'Conditional Break...', 13},
		{'Function Break...', 0},
		separator,
		{'Enable All', no},
		{'Disable All', no},
		{'Delete All', 0},
		separator]},
     {'Windows', []},
     {'Help', [{'Debugger', no}]}].

shortcut(c) -> 'Close';
shortcut(g) -> 'Go To Line';
shortcut(s) -> 'Search';
shortcut(b) -> 'Line Break...';
shortcut(r) -> 'Conditional Break...';
shortcut(f) -> 'Function Break...';
shortcut(d) -> 'Delete All';

shortcut(_) -> false.

gui_load_module(Win, Mod) ->
    dbg_wx_trace_win:display(Win,{text, "Loading module..."}),
    {ok, Contents} = dbg_iserver:call({raw_contents, Mod, any}),
    Win2 = dbg_wx_trace_win:show_code(Win, Mod, Contents),
    dbg_wx_trace_win:display(Win,{text, ""}),
    Win2.
