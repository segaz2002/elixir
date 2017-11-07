defmodule DynamicSupervisor do
  @moduledoc ~S"""
  A supervisor that starts children dynamically.

  The `Supervisor` was designed to handle mostly static children, that
  are started when the supervisor starts. On the other hand, the
  `DynamicSupervisor` is started with a single child specification and
  it does not start any child when it boots. Instead, children are
  started by demand via `start_child/2`.
  """

  @behaviour GenServer

  @doc """
  Callback invoked to start the supervisor and during hot code upgrades.
  """
  @callback init(args :: term) ::
              {:ok, {sup_flags(), [:supervisor.child_spec()]}}
              | :ignore

  @type sup_flags() :: %{
          strategy: strategy(),
          intensity: non_neg_integer(),
          period: pos_integer(),
          max_dynamic: non_neg_integer()
        }

  @typedoc "Option values used by the `start*` functions"
  @type option :: {:name, Supervisor.name()} | flag()

  @typedoc "Options used by the `start*` functions"
  @type options :: [option, ...]

  @typedoc "Options given to `start_link/2` and `init/2`"
  @type flag ::
          {:strategy, strategy}
          | {:max_restarts, non_neg_integer}
          | {:max_seconds, pos_integer}
          | {:max_dynamic, non_neg_integer | :infinity}

  @typedoc "Supported strategies"
  @type strategy :: :one_for_one | :one_for_all | :rest_for_one

  defstruct [
    :args,
    :mod,
    :name,
    :strategy,
    :template,
    :max_restarts,
    :max_seconds,
    :max_dynamic,
    children: %{},
    restarts: [],
    dynamic: 0
  ]

  @doc false
  defmacro __using__(opts) do
    quote location: :keep do
      @behaviour DynamicSupervisor
      @opts unquote(opts)

      @doc false
      def child_spec(arg) do
        default = %{
          id: __MODULE__,
          start: {__MODULE__, :start_link, [arg]},
          type: :supervisor
        }

        Supervisor.child_spec(default, @opts)
      end

      defoverridable child_spec: 1

      @doc false
      def init(arg)
    end
  end

  @doc """
  TODO
  """
  @spec start_link([:supervisor.child_spec() | {module, term} | module], options) ::
          Supervisor.on_start()
  def start_link(children, options) when is_list(children) do
    keys = [:strategy, :max_seconds, :max_restarts, :max_dynamic]
    {sup_opts, start_opts} = Keyword.split(options, keys)
    start_link(Supervisor.Default, {__MODULE__, children, sup_opts}, start_opts)
  end

  @doc """
  TODO
  """
  def init(children, opts) when is_list(children) and is_list(opts) do
    {:ok, {flags, children}} = Supervisor.init(children, opts)
    max_dynamic = Keyword.get(opts, :max_dynamic, :infinity)
    {:ok, {Map.put(flags, :max_dynamic, max_dynamic), children}}
  end

  @doc """
  TODO
  """
  @spec start_link(module, term, GenServer.options()) :: Supervisor.on_start()
  def start_link(mod, args, opts \\ []) do
    GenServer.start_link(__MODULE__, {mod, args, opts[:name]}, opts)
  end

  @doc """
  TODO
  """
  @spec start_child(Supervisor.supervisor(), [term]) :: Supervisor.on_start_child()
  def start_child(supervisor, args) when is_list(args) do
    # TODO: Rename this to start_child_with_arguments
    call(supervisor, {:start_child, args})
  end

  @doc """
  TODO
  """
  @spec terminate_child(Supervisor.supervisor(), pid) :: :ok | {:error, :not_found}
  def terminate_child(supervisor, pid) when is_pid(pid) do
    call(supervisor, {:terminate_child, pid})
  end

  @doc """
  Returns a list with information about all children.

  Note that calling this function when supervising a large number
  of children under low memory conditions can cause an out of memory
  exception.

  This function returns a list of tuples containing:

    * `id` - as defined in the child specification but is always
      set to `:undefined` for dynamic supervisors

    * `child` - the pid of the corresponding child process or the
      atom `:restarting` if the process is about to be restarted

    * `type` - `:worker` or `:supervisor` as defined in the child
      specification

    * `modules` - as defined in the child specification

  """
  @spec which_children(Supervisor.supervisor()) :: [
          {:undefined, pid | :restarting, :worker | :supervisor, :supervisor.modules()}
        ]
  def which_children(supervisor) do
    call(supervisor, :which_children)
  end

  @doc """
  Returns a map containing count values for the supervisor.

  The map contains the following keys:

    * `:specs` - always 1 as dynamic supervisors have a single specification

    * `:active` - the count of all actively running child processes managed by
      this supervisor

    * `:supervisors` - the count of all supervisors whether or not the child
      process is still alive

    * `:workers` - the count of all workers, whether or not the child process
      is still alive

  """
  @spec count_children(Supervisor.supervisor()) :: %{
          specs: non_neg_integer,
          active: non_neg_integer,
          supervisors: non_neg_integer,
          workers: non_neg_integer
        }
  def count_children(supervisor) do
    call(supervisor, :count_children)
  end

  @compile {:inline, call: 2}

  defp call(supervisor, req) do
    GenServer.call(supervisor, req, :infinity)
  end

  ## Callbacks

  @impl true
  def init({mod, args, name}) do
    Process.put(:"$initial_call", {:supervisor, mod, 1})
    Process.flag(:trap_exit, true)

    case mod.init(args) do
      {:ok, {flags, children}} when is_map(flags) ->
        case validate_template(children) do
          {:ok, template} ->
            state = %DynamicSupervisor{mod: mod, args: args, name: name || {self(), mod}}

            case init(state, template, flags) do
              {:ok, state} -> {:ok, state}
              {:error, reason} -> {:stop, {:supervisor_data, reason}}
            end

          {:error, reason} ->
            {:stop, reason}
        end

      :ignore ->
        :ignore

      other ->
        {:stop, {:bad_return_value, other}}
    end
  end

  defp init(state, template, flags) do
    strategy = Map.get(flags, :strategy, :one_for_one)
    max_restarts = Map.get(flags, :intensity, 1)
    max_seconds = Map.get(flags, :period, 5)
    max_dynamic = Map.get(flags, :max_dynamic, :infinity)

    with :ok <- validate_strategy(strategy),
         :ok <- validate_restarts(max_restarts),
         :ok <- validate_seconds(max_seconds),
         :ok <- validate_dynamic(max_dynamic) do
      {:ok, %{
        state
        | template: template,
          strategy: strategy,
          max_restarts: max_restarts,
          max_seconds: max_seconds,
          max_dynamic: max_dynamic
      }}
    end
  end

  defp validate_template([%{id: id, start: {mod, _, _} = start} = child]) do
    restart = Map.get(child, :restart, :permanent)
    shutdown = Map.get(child, :shutdown, 5_000)
    type = Map.get(child, :type, :worker)
    modules = Map.get(child, :modules, [mod])

    validate_template([{id, start, restart, shutdown, type, modules}])
  end

  defp validate_template([template] = children) do
    case :supervisor.check_childspecs(children) do
      :ok ->
        {_, mfa, restart, shutdown, type, modules} = template
        {:ok, {mfa, restart, shutdown, type, modules}}

      {:error, reason} ->
        {:error, {:start_spec, reason}}
    end
  end

  defp validate_template(children) do
    {:error, {:bad_start_spec, children}}
  end

  defp validate_strategy(strategy) when strategy in [:one_for_one], do: :ok
  defp validate_strategy(strategy), do: {:error, {:invalid_strategy, strategy}}

  defp validate_restarts(restart) when is_integer(restart) and restart >= 0, do: :ok
  defp validate_restarts(restart), do: {:error, {:invalid_intensity, restart}}

  defp validate_seconds(seconds) when is_integer(seconds) and seconds > 0, do: :ok
  defp validate_seconds(seconds), do: {:error, {:invalid_period, seconds}}

  defp validate_dynamic(:infinity), do: :ok
  defp validate_dynamic(dynamic) when is_integer(dynamic) and dynamic >= 0, do: :ok
  defp validate_dynamic(dynamic), do: {:error, {:invalid_max_dynamic, dynamic}}

  @impl true
  def handle_call(:which_children, _from, state) do
    %{children: children} = state

    reply =
      for {pid, args} <- children do
        case args do
          {:restarting, {_, _, _, type, modules}} ->
            {:undefined, :restarting, type, modules}

          {_, _, _, type, modules} ->
            {:undefined, pid, type, modules}
        end
      end

    {:reply, reply, state}
  end

  def handle_call(:count_children, _from, state) do
    %{children: children} = state
    specs = map_size(children)

    {active, workers, supervisors} =
      Enum.reduce(children, {0, 0, 0}, fn
        {_pid, {:restarting, {_, _, _, :worker, _}}}, {active, worker, supervisor} ->
          {active, worker + 1, supervisor}

        {_pid, {:restarting, {_, _, _, :supervisor, _}}}, {active, worker, supervisor} ->
          {active, worker, supervisor + 1}

        {_pid, {_, _, _, :worker, _}}, {active, worker, supervisor} ->
          {active + 1, worker + 1, supervisor}

        {_pid, {_, _, _, :supervisor, _}}, {active, worker, supervisor} ->
          {active + 1, worker, supervisor + 1}
      end)

    reply = %{specs: specs, active: active, workers: workers, supervisors: supervisors}
    {:reply, reply, state}
  end

  def handle_call({:terminate_child, pid}, _from, %{children: children} = state) do
    case children do
      %{^pid => info} ->
        :ok = terminate_children(%{pid => info}, state)
        {:reply, :ok, delete_child(pid, state)}

      %{} ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:start_child, extra}, _from, state) do
    %{dynamic: dynamic, max_dynamic: max_dynamic, template: child} = state

    if dynamic < max_dynamic do
      handle_start_child(child, extra, %{state | dynamic: dynamic + 1})
    else
      {:reply, {:error, :max_dynamic}, state}
    end
  end

  defp handle_start_child({{m, f, args}, restart, shutdown, type, modules}, extra, state) do
    args = args ++ extra

    case reply = start_child(m, f, args) do
      {:ok, pid, _} ->
        {:reply, reply, save_child(pid, {m, f, args}, restart, shutdown, type, modules, state)}

      {:ok, pid} ->
        {:reply, reply, save_child(pid, {m, f, args}, restart, shutdown, type, modules, state)}

      _ ->
        {:reply, reply, update_in(state.dynamic, &(&1 - 1))}
    end
  end

  defp start_child(m, f, a) do
    try do
      apply(m, f, a)
    catch
      kind, reason ->
        {:error, exit_reason(kind, reason, System.stacktrace())}
    else
      {:ok, pid, extra} when is_pid(pid) -> {:ok, pid, extra}
      {:ok, pid} when is_pid(pid) -> {:ok, pid}
      :ignore -> :ignore
      {:error, _} = error -> error
      other -> {:error, other}
    end
  end

  defp save_child(pid, {m, f, _}, :temporary, shutdown, type, modules, state) do
    put_in(state.children[pid], {{m, f, :undefined}, :temporary, shutdown, type, modules})
  end

  defp save_child(pid, mfa, restart, shutdown, type, modules, state) do
    put_in(state.children[pid], {mfa, restart, shutdown, type, modules})
  end

  defp exit_reason(:exit, reason, _), do: reason
  defp exit_reason(:error, reason, stack), do: {reason, stack}
  defp exit_reason(:throw, value, stack), do: {{:nocatch, value}, stack}

  @impl true
  def handle_cast(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info({:EXIT, pid, reason}, state) do
    case maybe_restart_child(pid, reason, state) do
      {:ok, state} -> {:noreply, state}
      {:shutdown, state} -> {:stop, :shutdown, state}
    end
  end

  def handle_info({:"$gen_restart", pid}, state) do
    %{children: children, template: child} = state

    case children do
      %{^pid => restarting_args} ->
        {:restarting, child} = restarting_args

        case restart_child(pid, child, state) do
          {:ok, state} -> {:noreply, state}
          {:shutdown, state} -> {:stop, :shutdown, state}
        end

      # We may hit clause if we send $gen_restart and then
      # someone calls terminate_child, removing the child.
      %{} ->
        {:noreply, state}
    end
  end

  def handle_info(msg, state) do
    :error_logger.error_msg('DynamicSupervisor received unexpected message: ~p~n', [msg])
    {:noreply, state}
  end

  @impl true
  def code_change(_, %{mod: mod, args: args} = state, _) do
    case mod.init(args) do
      {:ok, {flags, children}} when is_map(flags) ->
        case validate_template(children) do
          {:ok, template} ->
            case init(state, template, flags) do
              {:ok, state} -> {:ok, state}
              {:error, reason} -> {:error, {:supervisor_data, reason}}
            end

          {:error, reason} ->
            {:error, reason}
        end

      :ignore ->
        {:ok, state}

      error ->
        error
    end
  end

  @impl true
  def terminate(_, %{children: children} = state) do
    :ok = terminate_children(children, state)
  end

  defp terminate_children(children, state) do
    {pids, times, stacks} = monitor_children(children)
    size = map_size(pids)

    timers =
      Enum.reduce(times, %{}, fn {time, pids}, acc ->
        Map.put(acc, :erlang.start_timer(time, self(), :kill), pids)
      end)

    stacks = wait_children(pids, size, timers, stacks)

    for {pid, {child, reason}} <- stacks do
      report_error(:shutdown_error, reason, pid, child, state)
    end

    :ok
  end

  defp monitor_children(children) do
    Enum.reduce(children, {%{}, %{}, %{}}, fn
      {_, {:restarting, _}}, acc ->
        acc

      {pid, {_, restart, _, _, _} = child}, {pids, times, stacks} ->
        case monitor_child(pid) do
          :ok ->
            times = exit_child(pid, child, times)
            {Map.put(pids, pid, child), times, stacks}

          {:error, :normal} when restart != :permanent ->
            {pids, times, stacks}

          {:error, reason} ->
            {pids, times, Map.put(stacks, pid, {child, reason})}
        end
    end)
  end

  defp monitor_child(pid) do
    ref = Process.monitor(pid)
    Process.unlink(pid)

    receive do
      {:EXIT, ^pid, reason} ->
        receive do
          {:DOWN, ^ref, :process, ^pid, _} -> {:error, reason}
        end
    after
      0 -> :ok
    end
  end

  defp exit_child(pid, {_, _, shutdown, _, _}, times) do
    case shutdown do
      :brutal_kill ->
        Process.exit(pid, :kill)
        times

      :infinity ->
        Process.exit(pid, :shutdown)
        times

      time ->
        Process.exit(pid, :shutdown)
        Map.update(times, time, [pid], &[pid | &1])
    end
  end

  defp wait_children(_pids, 0, timers, stacks) do
    for {timer, _} <- timers do
      _ = :erlang.cancel_timer(timer)

      receive do
        {:timeout, ^timer, :kill} -> :ok
      after
        0 -> :ok
      end
    end

    stacks
  end

  defp wait_children(pids, size, timers, stacks) do
    receive do
      {:DOWN, _ref, :process, pid, reason} ->
        case pids do
          %{^pid => child} ->
            stacks = wait_child(pid, child, reason, stacks)
            wait_children(pids, size - 1, timers, stacks)

          %{} ->
            wait_children(pids, size, timers, stacks)
        end

      {:timeout, timer, :kill} ->
        for pid <- Map.fetch!(timers, timer), do: Process.exit(pid, :kill)
        wait_children(pids, size, Map.delete(timers, timer), stacks)
    end
  end

  defp wait_child(pid, {_, _, :brutal_kill, _, _} = child, reason, stacks) do
    case reason do
      :killed -> stacks
      _ -> Map.put(stacks, pid, {child, reason})
    end
  end

  defp wait_child(pid, {_, restart, _, _, _} = child, reason, stacks) do
    case reason do
      :shutdown -> stacks
      :normal when restart != :permanent -> stacks
      reason -> Map.put(stacks, pid, {child, reason})
    end
  end

  defp maybe_restart_child(pid, reason, %{children: children} = state) do
    case children do
      %{^pid => {_, restart, _, _, _} = child} ->
        maybe_restart_child(restart, reason, pid, child, state)

      %{} ->
        {:ok, state}
    end
  end

  defp maybe_restart_child(:permanent, reason, pid, child, state) do
    report_error(:child_terminated, reason, pid, child, state)
    restart_child(pid, child, state)
  end

  defp maybe_restart_child(_, :normal, pid, _child, state) do
    {:ok, delete_child(pid, state)}
  end

  defp maybe_restart_child(_, :shutdown, pid, _child, state) do
    {:ok, delete_child(pid, state)}
  end

  defp maybe_restart_child(_, {:shutdown, _}, pid, _child, state) do
    {:ok, delete_child(pid, state)}
  end

  defp maybe_restart_child(:transient, reason, pid, child, state) do
    report_error(:child_terminated, reason, pid, child, state)
    restart_child(pid, child, state)
  end

  defp maybe_restart_child(:temporary, reason, pid, child, state) do
    report_error(:child_terminated, reason, pid, child, state)
    {:ok, delete_child(pid, state)}
  end

  defp delete_child(pid, state) do
    %{children: children, dynamic: dynamic} = state
    %{state | children: Map.delete(children, pid), dynamic: dynamic - 1}
  end

  defp restart_child(pid, child, state) do
    case add_restart(state) do
      {:ok, %{strategy: strategy} = state} ->
        case restart_child(strategy, pid, child, state) do
          {:ok, state} ->
            {:ok, state}

          {:try_again, state} ->
            send(self(), {:"$gen_restart", pid})
            {:ok, state}
        end

      {:shutdown, state} ->
        report_error(:shutdown, :reached_max_restart_intensity, pid, child, state)
        {:shutdown, delete_child(pid, state)}
    end
  end

  defp add_restart(state) do
    %{max_seconds: max_seconds, max_restarts: max_restarts, restarts: restarts} = state
    now = :erlang.monotonic_time(1)
    restarts = add_restart([now | restarts], now, max_seconds)
    state = %{state | restarts: restarts}

    if length(restarts) <= max_restarts do
      {:ok, state}
    else
      {:shutdown, state}
    end
  end

  defp add_restart(restarts, now, period) do
    for then <- restarts, now <= then + period, do: then
  end

  defp restart_child(:one_for_one, current_pid, child, state) do
    {{m, f, args} = mfa, restart, shutdown, type, modules} = child

    case start_child(m, f, args) do
      {:ok, pid, _} ->
        state = delete_child(current_pid, state)
        {:ok, save_child(pid, mfa, restart, shutdown, type, modules, state)}

      {:ok, pid} ->
        state = delete_child(current_pid, state)
        {:ok, save_child(pid, mfa, restart, shutdown, type, modules, state)}

      :ignore ->
        {:ok, delete_child(current_pid, state)}

      {:error, reason} ->
        report_error(:start_error, reason, {:restarting, current_pid}, child, state)
        state = put_in(state.children[current_pid], {:restarting, child})
        {:try_again, state}
    end
  end

  defp report_error(error, reason, pid, child, %{name: name}) do
    :error_logger.error_report(
      :supervision_report,
      supervisor: name,
      errorContext: error,
      reason: reason,
      offender: extract_child(pid, child)
    )
  end

  defp extract_child(pid, {mfa, restart, shutdown, type, _modules}) do
    [
      pid: pid,
      id: :undefined,
      mfargs: mfa,
      restart_type: restart,
      shutdown: shutdown,
      child_type: type
    ]
  end

  @impl true
  def format_status(:terminate, [_pdict, state]) do
    state
  end

  def format_status(_, [_pdict, %{mod: mod} = state]) do
    [data: [{~c"State", state}], supervisor: [{~c"Callback", mod}]]
  end
end
