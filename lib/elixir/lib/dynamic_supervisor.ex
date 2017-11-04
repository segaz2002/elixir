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
    restarting: 0,
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
      :ok -> {:ok, template}
      {:error, reason} -> {:error, {:start_spec, reason}}
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
    %{children: children, template: child} = state
    {_, _, _, _, type, mods} = child

    reply =
      for {pid, args} <- children do
        maybe_pid =
          case args do
            {:restarting, _} -> :restarting
            _ -> pid
          end

        {:undefined, maybe_pid, type, mods}
      end

    {:reply, reply, state}
  end

  def handle_call(:count_children, _from, state) do
    %{children: children, template: child, restarting: restarting} = state
    {_, _, _, _, type, _} = child

    specs = map_size(children)
    active = specs - restarting

    reply =
      case type do
        :supervisor ->
          %{specs: 1, active: active, workers: 0, supervisors: specs}

        :worker ->
          %{specs: 1, active: active, workers: specs, supervisors: 0}
      end

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

  defp handle_start_child({_, {m, f, args}, restart, _, _, _}, extra, state) do
    args = args ++ extra

    case reply = start_child(m, f, args) do
      {:ok, pid, _} ->
        {:reply, reply, save_child(restart, pid, args, state)}

      {:ok, pid} ->
        {:reply, reply, save_child(restart, pid, args, state)}

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

  defp save_child(:temporary, pid, _, state), do: put_in(state.children[pid], :undefined)
  defp save_child(_, pid, args, state), do: put_in(state.children[pid], args)

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
      {:ok, state} ->
        {:noreply, state}

      {:shutdown, state} ->
        {:stop, :shutdown, state}
    end
  end

  def handle_info({:"$gen_restart", pid}, state) do
    %{children: children, template: child, restarting: restarting} = state
    state = %{state | restarting: restarting - 1}

    case children do
      %{^pid => restarting_args} ->
        {:restarting, args} = restarting_args

        case restart_child(pid, args, child, state) do
          {:ok, state} ->
            {:noreply, state}

          {:shutdown, state} ->
            {:stop, :shutdown, state}
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

  defp terminate_children(children, %{template: template} = state) do
    {_, _, restart, shutdown, _, _} = template

    {pids, stacks} = monitor_children(children, restart)
    size = map_size(pids)

    stacks =
      case shutdown do
        :brutal_kill ->
          for {pid, _} <- pids, do: Process.exit(pid, :kill)
          wait_children(restart, shutdown, pids, size, nil, stacks)

        :infinity ->
          for {pid, _} <- pids, do: Process.exit(pid, :shutdown)
          wait_children(restart, shutdown, pids, size, nil, stacks)

        time ->
          for {pid, _} <- pids, do: Process.exit(pid, :shutdown)
          timer = :erlang.start_timer(time, self(), :kill)
          wait_children(restart, shutdown, pids, size, timer, stacks)
      end

    for {pid, reason} <- stacks do
      report_error(:shutdown_error, reason, pid, :undefined, template, state)
    end

    :ok
  end

  defp monitor_children(children, restart) do
    Enum.reduce(children, {%{}, %{}}, fn
      {_, {:restarting, _}}, {pids, stacks} ->
        {pids, stacks}

      {pid, _}, {pids, stacks} ->
        case monitor_child(pid) do
          :ok ->
            {Map.put(pids, pid, true), stacks}

          {:error, :normal} when restart != :permanent ->
            {pids, stacks}

          {:error, reason} ->
            {pids, Map.put(stacks, pid, reason)}
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

  defp wait_children(_restart, _shutdown, _pids, 0, nil, stacks) do
    stacks
  end

  defp wait_children(_restart, _shutdown, _pids, 0, timer, stacks) do
    _ = :erlang.cancel_timer(timer)

    receive do
      {:timeout, ^timer, :kill} -> :ok
    after
      0 -> :ok
    end

    stacks
  end

  defp wait_children(restart, :brutal_kill, pids, size, timer, stacks) do
    receive do
      {:DOWN, _ref, :process, pid, :killed} ->
        wait_children(restart, :brutal_kill, Map.delete(pids, pid), size - 1, timer, stacks)

      {:DOWN, _ref, :process, pid, reason} ->
        stacks = Map.put(stacks, pid, reason)
        wait_children(restart, :brutal_kill, Map.delete(pids, pid), size - 1, timer, stacks)
    end
  end

  defp wait_children(restart, shutdown, pids, size, timer, stacks) do
    receive do
      {:DOWN, _ref, :process, pid, :shutdown} ->
        wait_children(restart, shutdown, Map.delete(pids, pid), size - 1, timer, stacks)

      {:DOWN, _ref, :process, pid, :normal} when restart != :permanent ->
        wait_children(restart, shutdown, Map.delete(pids, pid), size - 1, timer, stacks)

      {:DOWN, _ref, :process, pid, reason} ->
        stacks = Map.put(stacks, pid, reason)
        wait_children(restart, shutdown, Map.delete(pids, pid), size - 1, timer, stacks)

      {:timeout, ^timer, :kill} ->
        for {pid, _} <- pids, do: Process.exit(pid, :kill)
        wait_children(restart, shutdown, pids, size, nil, stacks)
    end
  end

  defp maybe_restart_child(pid, reason, state) do
    %{children: children, template: child} = state
    {_, _, restart, _, _, _} = child

    case children do
      %{^pid => args} -> maybe_restart_child(restart, reason, pid, args, child, state)
      %{} -> {:ok, state}
    end
  end

  defp maybe_restart_child(:permanent, reason, pid, args, child, state) do
    report_error(:child_terminated, reason, pid, args, child, state)
    restart_child(pid, args, child, state)
  end

  defp maybe_restart_child(_, :normal, pid, _args, _child, state) do
    {:ok, delete_child(pid, state)}
  end

  defp maybe_restart_child(_, :shutdown, pid, _args, _child, state) do
    {:ok, delete_child(pid, state)}
  end

  defp maybe_restart_child(_, {:shutdown, _}, pid, _args, _child, state) do
    {:ok, delete_child(pid, state)}
  end

  defp maybe_restart_child(:transient, reason, pid, args, child, state) do
    report_error(:child_terminated, reason, pid, args, child, state)
    restart_child(pid, args, child, state)
  end

  defp maybe_restart_child(:temporary, reason, pid, args, child, state) do
    report_error(:child_terminated, reason, pid, args, child, state)
    {:ok, delete_child(pid, state)}
  end

  defp delete_child(pid, state) do
    %{children: children, dynamic: dynamic} = state
    %{state | children: Map.delete(children, pid), dynamic: dynamic - 1}
  end

  defp restart_child(pid, args, child, state) do
    case add_restart(state) do
      {:ok, %{strategy: strategy} = state} ->
        case restart_child(strategy, pid, args, child, state) do
          {:ok, state} ->
            {:ok, state}

          {:try_again, state} ->
            send(self(), {:"$gen_restart", pid})
            {:ok, state}
        end

      {:shutdown, state} ->
        report_error(:shutdown, :reached_max_restart_intensity, pid, args, child, state)
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

  defp restart_child(:one_for_one, current_pid, args, child, state) do
    {_, {m, f, _}, restart, _, _, _} = child

    case start_child(m, f, args) do
      {:ok, pid, _} ->
        {:ok, save_child(restart, pid, args, delete_child(current_pid, state))}

      {:ok, pid} ->
        {:ok, save_child(restart, pid, args, delete_child(current_pid, state))}

      :ignore ->
        {:ok, delete_child(current_pid, state)}

      {:error, reason} ->
        report_error(:start_error, reason, {:restarting, current_pid}, args, child, state)
        state = restart_child(current_pid, state)
        {:try_again, update_in(state.restarting, &(&1 + 1))}
    end
  end

  defp restart_child(pid, %{children: children} = state) do
    case children do
      %{^pid => {:restarting, _}} ->
        state

      %{^pid => args} ->
        %{state | children: Map.put(children, pid, {:restarting, args})}
    end
  end

  defp report_error(error, reason, pid, args, child, %{name: name}) do
    :error_logger.error_report(
      :supervision_report,
      supervisor: name,
      errorContext: error,
      reason: reason,
      offender: extract_child(pid, args, child)
    )
  end

  defp extract_child(pid, args, {id, {m, f, _}, restart, shutdown, type, _}) do
    [
      pid: pid,
      id: id,
      mfargs: {m, f, args},
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
