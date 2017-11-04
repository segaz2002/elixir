Code.require_file("test_helper.exs", __DIR__)

defmodule DynamicSupervisorTest do
  use ExUnit.Case, async: true

  defmodule Simple do
    use DynamicSupervisor

    def init(args), do: args
  end

  describe "use/2" do
    test "generates child_spec/1" do
      assert Simple.child_spec([:hello]) == %{
               id: Simple,
               start: {Simple, :start_link, [[:hello]]},
               type: :supervisor
             }

      defmodule Custom do
        use DynamicSupervisor,
          id: :id,
          restart: :temporary,
          shutdown: :infinity,
          start: {:foo, :bar, []}

        def init(arg), do: {:producer, arg}
      end

      assert Custom.child_spec([:hello]) == %{
               id: :id,
               restart: :temporary,
               shutdown: :infinity,
               start: {:foo, :bar, []},
               type: :supervisor
             }
    end
  end

  describe "init/2" do
    test "supports old child spec" do
      flags = %{strategy: :one_for_one, intensity: 3, period: 5, max_dynamic: :infinity}
      specs = [{Foo, {Foo, :start_link, []}, :permanent, 5000, :worker, [Foo]}]

      worker = Supervisor.Spec.worker(Foo, [])
      assert DynamicSupervisor.init([worker], strategy: :one_for_one) == {:ok, {flags, specs}}
    end

    test "supports new child spec as tuple" do
      flags = %{strategy: :one_for_one, intensity: 3, period: 5, max_dynamic: :infinity}
      specs = [%{id: Task, restart: :temporary, start: {Task, :start_link, [[:foo, :bar]]}}]

      assert DynamicSupervisor.init([{Task, [:foo, :bar]}], strategy: :one_for_one) ==
               {:ok, {flags, specs}}
    end

    test "supports new child spec as atom" do
      flags = %{strategy: :one_for_one, intensity: 3, period: 5, max_dynamic: :infinity}
      specs = [%{id: Task, restart: :temporary, start: {Task, :start_link, [[]]}}]

      assert DynamicSupervisor.init([Task], strategy: :one_for_one) == {:ok, {flags, specs}}
    end

    test "supports new child spec with options" do
      flags = %{strategy: :one_for_one, intensity: 1, period: 1, max_dynamic: 10}
      specs = [%{id: Task, restart: :temporary, start: {Task, :start_link, [[]]}}]

      opts = [strategy: :one_for_one, max_seconds: 1, max_restarts: 1, max_dynamic: 10]
      assert DynamicSupervisor.init([Task], opts) == {:ok, {flags, specs}}
    end
  end

  describe "start_link/3" do
    test "with non-ok init" do
      Process.flag(:trap_exit, true)
      worker = %{id: Foo, start: {Foo, :start_link, []}}

      assert DynamicSupervisor.start_link(Simple, {:ok, {%{}, []}}) ==
               {:error, {:bad_start_spec, []}}

      assert DynamicSupervisor.start_link(Simple, {:ok, {%{}, [1, 2]}}) ==
               {:error, {:bad_start_spec, [1, 2]}}

      assert DynamicSupervisor.start_link(Simple, {:ok, {%{strategy: :unknown}, [worker]}}) ==
               {:error, {:supervisor_data, {:invalid_strategy, :unknown}}}

      assert DynamicSupervisor.start_link(Simple, {:ok, {%{intensity: -1}, [worker]}}) ==
               {:error, {:supervisor_data, {:invalid_intensity, -1}}}

      assert DynamicSupervisor.start_link(Simple, {:ok, {%{period: 0}, [worker]}}) ==
               {:error, {:supervisor_data, {:invalid_period, 0}}}

      assert DynamicSupervisor.start_link(Simple, {:ok, {%{max_dynamic: -1}, [worker]}}) ==
               {:error, {:supervisor_data, {:invalid_max_dynamic, -1}}}

      assert DynamicSupervisor.start_link(Simple, {:ok, {%{}, [%{id: Foo, start: :bar}]}}) ==
               {:error, {:start_spec, {:invalid_mfa, :bar}}}

      assert DynamicSupervisor.start_link(Simple, :unknown) ==
               {:error, {:bad_return_value, :unknown}}

      assert DynamicSupervisor.start_link(Simple, :ignore) == :ignore
    end

    test "with registered process" do
      worker = sleepy_worker()
      {:ok, pid} = DynamicSupervisor.start_link(Simple, {:ok, {%{}, [worker]}}, name: __MODULE__)

      # Sets up a link
      {:links, links} = Process.info(self(), :links)
      assert pid in links

      # A name
      assert Process.whereis(__MODULE__) == pid

      # And the initial call
      assert {:supervisor, DynamicSupervisorTest.Simple, 1} =
               :proc_lib.translate_initial_call(pid)
    end

    test "with map childspec" do
      worker = sleepy_worker()
      {:ok, pid} = DynamicSupervisor.start_link(Simple, {:ok, {%{}, [worker]}}, name: __MODULE__)

      # Sets up a link
      {:links, links} = Process.info(self(), :links)
      assert pid in links

      # A name
      assert Process.whereis(__MODULE__) == pid

      # And the initial call
      assert {:supervisor, DynamicSupervisorTest.Simple, 1} =
               :proc_lib.translate_initial_call(pid)
    end

    test "sets initial call to the same as a regular supervisor" do
      {:ok, pid} = Supervisor.start_link([], strategy: :one_for_one)
      assert :proc_lib.initial_call(pid) == {:supervisor, Supervisor.Default, [:Argument__1]}

      worker = sleepy_worker()
      {:ok, pid} = DynamicSupervisor.start_link([worker], strategy: :one_for_one)
      assert :proc_lib.initial_call(pid) == {:supervisor, Supervisor.Default, [:Argument__1]}
    end

    test "returns the callback module" do
      {:ok, pid} = Supervisor.start_link([], strategy: :one_for_one)
      assert :supervisor.get_callback_module(pid) == Supervisor.Default

      {:ok, pid} = DynamicSupervisor.start_link([Simple], strategy: :one_for_one)
      assert :supervisor.get_callback_module(pid) == Supervisor.Default
    end
  end

  ## Code change

  describe "code_change/3" do
    test "with non-ok init" do
      worker = sleepy_worker()
      {:ok, pid} = DynamicSupervisor.start_link(Simple, {:ok, {%{}, [worker]}})

      assert fake_upgrade(pid, {:ok, {%{}, []}}) == {:error, {:error, {:bad_start_spec, []}}}

      assert fake_upgrade(pid, {:ok, {%{}, [1, 2]}}) ==
               {:error, {:error, {:bad_start_spec, [1, 2]}}}

      assert fake_upgrade(pid, {:ok, {%{strategy: :unknown}, [worker]}}) ==
               {:error, {:error, {:supervisor_data, {:invalid_strategy, :unknown}}}}

      assert fake_upgrade(pid, {:ok, {%{intensity: -1}, [worker]}}) ==
               {:error, {:error, {:supervisor_data, {:invalid_intensity, -1}}}}

      assert fake_upgrade(pid, {:ok, {%{period: 0}, [worker]}}) ==
               {:error, {:error, {:supervisor_data, {:invalid_period, 0}}}}

      assert fake_upgrade(pid, {:ok, {%{max_dynamic: -1}, [worker]}}) ==
               {:error, {:error, {:supervisor_data, {:invalid_max_dynamic, -1}}}}

      assert fake_upgrade(pid, {:ok, {%{}, [%{id: Foo, start: :bar}]}}) ==
               {:error, {:error, {:start_spec, {:invalid_mfa, :bar}}}}

      assert fake_upgrade(pid, :unknown) == {:error, :unknown}
      assert fake_upgrade(pid, :ignore) == :ok
    end

    test "with ok init" do
      {:ok, pid} = DynamicSupervisor.start_link(Simple, {:ok, {%{}, [sleepy_worker()]}})

      {:ok, _} = DynamicSupervisor.start_child(pid, [])
      assert %{active: 1} = DynamicSupervisor.count_children(pid)

      worker = %{id: Task, start: {Task, :start_link, [Kernel, :send]}, restart: :temporary}
      assert fake_upgrade(pid, {:ok, {%{}, [worker]}}) == :ok
      assert %{active: 1} = DynamicSupervisor.count_children(pid)

      {:ok, _} = DynamicSupervisor.start_child(pid, [[self(), :sample]])
      assert_receive :sample
    end

    defp fake_upgrade(pid, args) do
      :ok = :sys.suspend(pid)
      :sys.replace_state(pid, fn state -> %{state | args: args} end)
      res = :sys.change_code(pid, :gen_server, 123, :extra)
      :ok = :sys.resume(pid)
      res
    end
  end

  describe "start_child/2" do
    test "with different returns" do
      children = [current_module_worker()]
      {:ok, pid} = DynamicSupervisor.start_link(children, strategy: :one_for_one)

      assert {:ok, _, :extra} = DynamicSupervisor.start_child(pid, [:ok3])
      assert {:ok, _} = DynamicSupervisor.start_child(pid, [:ok2])
      assert {:error, :found} = DynamicSupervisor.start_child(pid, [:error])
      assert :ignore = DynamicSupervisor.start_child(pid, [:ignore])
      assert {:error, :unknown} = DynamicSupervisor.start_child(pid, [:unknown])
    end

    test "with throw/error/exit" do
      children = [%{id: __MODULE__, start: {__MODULE__, :start_link, [:non_local]}}]
      {:ok, pid} = DynamicSupervisor.start_link(children, strategy: :one_for_one)

      assert {:error, {{:nocatch, :oops}, [_ | _]}} = DynamicSupervisor.start_child(pid, [:throw])
      assert {:error, {%RuntimeError{}, [_ | _]}} = DynamicSupervisor.start_child(pid, [:error])
      assert {:error, :oops} = DynamicSupervisor.start_child(pid, [:exit])
    end

    test "with max_dynamic" do
      children = [current_module_worker()]
      opts = [strategy: :one_for_one, max_dynamic: 0]
      {:ok, pid} = DynamicSupervisor.start_link(children, opts)

      assert {:error, :max_dynamic} = DynamicSupervisor.start_child(pid, [:ok2])
    end

    test "temporary child is not restarted regardless of reason" do
      children = [current_module_worker(restart: :temporary)]
      {:ok, pid} = DynamicSupervisor.start_link(children, strategy: :one_for_one)

      assert {:ok, child} = DynamicSupervisor.start_child(pid, [:ok2])
      assert_kill(child, :shutdown)
      assert %{workers: 0, active: 0} = DynamicSupervisor.count_children(pid)

      assert {:ok, child} = DynamicSupervisor.start_child(pid, [:ok2])
      assert_kill(child, :whatever)
      assert %{workers: 0, active: 0} = DynamicSupervisor.count_children(pid)
    end

    test "transient child is restarted unless normal/shutdown/{shutdown, _}" do
      children = [current_module_worker(restart: :transient)]
      {:ok, pid} = DynamicSupervisor.start_link(children, strategy: :one_for_one)

      assert {:ok, child} = DynamicSupervisor.start_child(pid, [:ok2])
      assert_kill(child, :shutdown)
      assert %{workers: 0, active: 0} = DynamicSupervisor.count_children(pid)

      assert {:ok, child} = DynamicSupervisor.start_child(pid, [:ok2])
      assert_kill(child, {:shutdown, :signal})
      assert %{workers: 0, active: 0} = DynamicSupervisor.count_children(pid)

      assert {:ok, child} = DynamicSupervisor.start_child(pid, [:ok2])
      assert_kill(child, :whatever)
      assert %{workers: 1, active: 1} = DynamicSupervisor.count_children(pid)
    end

    test "permanent child is restarted regardless of reason" do
      children = [current_module_worker(restart: :permanent)]

      {:ok, pid} =
        DynamicSupervisor.start_link(children, strategy: :one_for_one, max_restarts: 100_000)

      assert {:ok, child} = DynamicSupervisor.start_child(pid, [:ok2])
      assert_kill(child, :shutdown)
      assert %{workers: 1, active: 1} = DynamicSupervisor.count_children(pid)

      assert {:ok, child} = DynamicSupervisor.start_child(pid, [:ok2])
      assert_kill(child, {:shutdown, :signal})
      assert %{workers: 2, active: 2} = DynamicSupervisor.count_children(pid)

      assert {:ok, child} = DynamicSupervisor.start_child(pid, [:ok2])
      assert_kill(child, :whatever)
      assert %{workers: 3, active: 3} = DynamicSupervisor.count_children(pid)
    end

    test "child is restarted with different values" do
      children = [current_module_worker(restart: :permanent)]

      {:ok, pid} =
        DynamicSupervisor.start_link(children, strategy: :one_for_one, max_restarts: 100_000)

      assert {:ok, child1} = DynamicSupervisor.start_child(pid, [:restart, :ok2])

      assert [{:undefined, ^child1, :worker, [DynamicSupervisorTest]}] =
               DynamicSupervisor.which_children(pid)

      assert_kill(child1, :shutdown)
      assert %{workers: 1, active: 1} = DynamicSupervisor.count_children(pid)

      assert {:ok, child2} = DynamicSupervisor.start_child(pid, [:restart, :ok3])

      assert [
               {:undefined, _, :worker, [DynamicSupervisorTest]},
               {:undefined, ^child2, :worker, [DynamicSupervisorTest]}
             ] = DynamicSupervisor.which_children(pid)

      assert_kill(child2, :shutdown)
      assert %{workers: 2, active: 2} = DynamicSupervisor.count_children(pid)

      assert {:ok, child3} = DynamicSupervisor.start_child(pid, [:restart, :ignore])

      assert [
               {:undefined, _, :worker, [DynamicSupervisorTest]},
               {:undefined, _, :worker, [DynamicSupervisorTest]},
               {:undefined, _, :worker, [DynamicSupervisorTest]}
             ] = DynamicSupervisor.which_children(pid)

      assert_kill(child3, :shutdown)
      assert %{workers: 2, active: 2} = DynamicSupervisor.count_children(pid)

      assert {:ok, child4} = DynamicSupervisor.start_child(pid, [:restart, :error])

      assert [
               {:undefined, _, :worker, [DynamicSupervisorTest]},
               {:undefined, _, :worker, [DynamicSupervisorTest]},
               {:undefined, _, :worker, [DynamicSupervisorTest]}
             ] = DynamicSupervisor.which_children(pid)

      assert_kill(child4, :shutdown)
      assert %{workers: 3, active: 2} = DynamicSupervisor.count_children(pid)

      assert {:ok, child5} = DynamicSupervisor.start_child(pid, [:restart, :unknown])

      assert [
               {:undefined, _, :worker, [DynamicSupervisorTest]},
               {:undefined, _, :worker, [DynamicSupervisorTest]},
               {:undefined, :restarting, :worker, [DynamicSupervisorTest]},
               {:undefined, _, :worker, [DynamicSupervisorTest]}
             ] = DynamicSupervisor.which_children(pid)

      assert_kill(child5, :shutdown)
      assert %{workers: 4, active: 2} = DynamicSupervisor.count_children(pid)
    end

    test "restarting children counted in max_dynamic" do
      children = [current_module_worker(restart: :permanent)]
      opts = [strategy: :one_for_one, max_dynamic: 1, max_restarts: 100_000]
      {:ok, pid} = DynamicSupervisor.start_link(children, opts)

      assert {:ok, child1} = DynamicSupervisor.start_child(pid, [:restart, :error])
      assert_kill(child1, :shutdown)
      assert %{workers: 1, active: 0} = DynamicSupervisor.count_children(pid)
      assert {:error, :max_dynamic} = DynamicSupervisor.start_child(pid, [:restart, :ok2])
    end

    test "child is restarted when trying again" do
      children = [current_module_worker(restart: :permanent)]
      {:ok, pid} = DynamicSupervisor.start_link(children, strategy: :one_for_one, max_restarts: 2)

      assert {:ok, child} = DynamicSupervisor.start_child(pid, [:try_again, self()])
      assert_received {:try_again, true}
      assert_kill(child, :shutdown)
      assert_receive {:try_again, false}
      assert_receive {:try_again, true}
      assert %{workers: 1, active: 1} = DynamicSupervisor.count_children(pid)
    end

    test "child triggers maximum restarts" do
      Process.flag(:trap_exit, true)
      children = [current_module_worker(restart: :permanent)]
      {:ok, pid} = DynamicSupervisor.start_link(children, strategy: :one_for_one, max_restarts: 1)

      assert {:ok, child} = DynamicSupervisor.start_child(pid, [:restart, :error])
      assert_kill(child, :shutdown)
      assert_receive {:EXIT, ^pid, :shutdown}
    end

    test "child triggers maximum intensity when trying again" do
      Process.flag(:trap_exit, true)
      children = [current_module_worker(restart: :permanent)]

      {:ok, pid} =
        DynamicSupervisor.start_link(children, strategy: :one_for_one, max_restarts: 10)

      assert {:ok, child} = DynamicSupervisor.start_child(pid, [:restart, :error])
      assert_kill(child, :shutdown)
      assert_receive {:EXIT, ^pid, :shutdown}
    end

    def start_link(:ok3), do: {:ok, spawn_link(fn -> :timer.sleep(:infinity) end), :extra}
    def start_link(:ok2), do: {:ok, spawn_link(fn -> :timer.sleep(:infinity) end)}
    def start_link(:error), do: {:error, :found}
    def start_link(:ignore), do: :ignore
    def start_link(:unknown), do: :unknown

    def start_link(:non_local, :throw), do: throw(:oops)
    def start_link(:non_local, :error), do: raise("oops")
    def start_link(:non_local, :exit), do: exit(:oops)

    def start_link(:try_again, notify) do
      if Process.get(:try_again) do
        Process.put(:try_again, false)
        send(notify, {:try_again, false})
        {:error, :try_again}
      else
        Process.put(:try_again, true)
        send(notify, {:try_again, true})
        start_link(:ok2)
      end
    end

    def start_link(:restart, value) do
      if Process.get({:restart, value}) do
        start_link(value)
      else
        Process.put({:restart, value}, true)
        start_link(:ok2)
      end
    end
  end

  describe "terminate/2" do
    test "terminates children with brutal kill" do
      Process.flag(:trap_exit, true)
      children = [task_worker(shutdown: :brutal_kill)]
      {:ok, sup} = DynamicSupervisor.start_link(children, strategy: :one_for_one)

      fun = fn -> :timer.sleep(:infinity) end
      assert {:ok, child1} = DynamicSupervisor.start_child(sup, [fun])
      assert {:ok, child2} = DynamicSupervisor.start_child(sup, [fun])
      assert {:ok, child3} = DynamicSupervisor.start_child(sup, [fun])

      Process.monitor(child1)
      Process.monitor(child2)
      Process.monitor(child3)
      assert_kill(sup, :shutdown)
      assert_receive {:DOWN, _, :process, ^child1, :killed}
      assert_receive {:DOWN, _, :process, ^child2, :killed}
      assert_receive {:DOWN, _, :process, ^child3, :killed}
    end

    test "terminates children with infinity shutdown" do
      Process.flag(:trap_exit, true)
      children = [task_worker(shutdown: :infinity)]
      {:ok, sup} = DynamicSupervisor.start_link(children, strategy: :one_for_one)

      fun = fn -> :timer.sleep(:infinity) end
      assert {:ok, child1} = DynamicSupervisor.start_child(sup, [fun])
      assert {:ok, child2} = DynamicSupervisor.start_child(sup, [fun])
      assert {:ok, child3} = DynamicSupervisor.start_child(sup, [fun])

      Process.monitor(child1)
      Process.monitor(child2)
      Process.monitor(child3)
      assert_kill(sup, :shutdown)
      assert_receive {:DOWN, _, :process, ^child1, :shutdown}
      assert_receive {:DOWN, _, :process, ^child2, :shutdown}
      assert_receive {:DOWN, _, :process, ^child3, :shutdown}
    end

    test "terminates children with infinity shutdown and abnormal reason" do
      Process.flag(:trap_exit, true)
      children = [task_worker(shutdown: :infinity)]
      {:ok, sup} = DynamicSupervisor.start_link(children, strategy: :one_for_one)

      fun = fn ->
        Process.flag(:trap_exit, true)
        receive(do: (_ -> exit({:shutdown, :oops})))
      end

      assert {:ok, child1} = DynamicSupervisor.start_child(sup, [fun])
      assert {:ok, child2} = DynamicSupervisor.start_child(sup, [fun])
      assert {:ok, child3} = DynamicSupervisor.start_child(sup, [fun])

      Process.monitor(child1)
      Process.monitor(child2)
      Process.monitor(child3)
      assert_kill(sup, :shutdown)
      assert_receive {:DOWN, _, :process, ^child1, {:shutdown, :oops}}
      assert_receive {:DOWN, _, :process, ^child2, {:shutdown, :oops}}
      assert_receive {:DOWN, _, :process, ^child3, {:shutdown, :oops}}
    end

    test "terminates children with integer shutdown" do
      Process.flag(:trap_exit, true)
      children = [task_worker(shutdown: 1000)]
      {:ok, sup} = DynamicSupervisor.start_link(children, strategy: :one_for_one)

      fun = fn -> :timer.sleep(:infinity) end
      assert {:ok, child1} = DynamicSupervisor.start_child(sup, [fun])
      assert {:ok, child2} = DynamicSupervisor.start_child(sup, [fun])
      assert {:ok, child3} = DynamicSupervisor.start_child(sup, [fun])

      Process.monitor(child1)
      Process.monitor(child2)
      Process.monitor(child3)
      assert_kill(sup, :shutdown)
      assert_receive {:DOWN, _, :process, ^child1, :shutdown}
      assert_receive {:DOWN, _, :process, ^child2, :shutdown}
      assert_receive {:DOWN, _, :process, ^child3, :shutdown}
    end

    test "terminates children with integer shutdown and abnormal reason" do
      Process.flag(:trap_exit, true)
      children = [task_worker(shutdown: 1000)]
      {:ok, sup} = DynamicSupervisor.start_link(children, strategy: :one_for_one)

      fun = fn ->
        Process.flag(:trap_exit, true)
        receive(do: (_ -> exit({:shutdown, :oops})))
      end

      assert {:ok, child1} = DynamicSupervisor.start_child(sup, [fun])
      assert {:ok, child2} = DynamicSupervisor.start_child(sup, [fun])
      assert {:ok, child3} = DynamicSupervisor.start_child(sup, [fun])

      Process.monitor(child1)
      Process.monitor(child2)
      Process.monitor(child3)
      assert_kill(sup, :shutdown)
      assert_receive {:DOWN, _, :process, ^child1, {:shutdown, :oops}}
      assert_receive {:DOWN, _, :process, ^child2, {:shutdown, :oops}}
      assert_receive {:DOWN, _, :process, ^child3, {:shutdown, :oops}}
    end

    test "terminates children with expired integer shutdown" do
      Process.flag(:trap_exit, true)
      children = [task_worker(shutdown: 1)]
      {:ok, sup} = DynamicSupervisor.start_link(children, strategy: :one_for_one)

      fun = fn ->
        :timer.sleep(:infinity)
      end

      tmt = fn ->
        Process.flag(:trap_exit, true)
        :timer.sleep(:infinity)
      end

      assert {:ok, child1} = DynamicSupervisor.start_child(sup, [fun])
      assert {:ok, child2} = DynamicSupervisor.start_child(sup, [tmt])
      assert {:ok, child3} = DynamicSupervisor.start_child(sup, [fun])

      Process.monitor(child1)
      Process.monitor(child2)
      Process.monitor(child3)
      assert_kill(sup, :shutdown)
      assert_receive {:DOWN, _, :process, ^child1, :shutdown}
      assert_receive {:DOWN, _, :process, ^child2, :killed}
      assert_receive {:DOWN, _, :process, ^child3, :shutdown}
    end

    test "terminates children with permanent restart and normal reason" do
      Process.flag(:trap_exit, true)
      children = [task_worker(shutdown: :infinity, restart: :permanent)]
      {:ok, sup} = DynamicSupervisor.start_link(children, strategy: :one_for_one)

      fun = fn ->
        Process.flag(:trap_exit, true)
        receive(do: (_ -> exit(:normal)))
      end

      assert {:ok, child1} = DynamicSupervisor.start_child(sup, [fun])
      assert {:ok, child2} = DynamicSupervisor.start_child(sup, [fun])
      assert {:ok, child3} = DynamicSupervisor.start_child(sup, [fun])

      Process.monitor(child1)
      Process.monitor(child2)
      Process.monitor(child3)
      assert_kill(sup, :shutdown)
      assert_receive {:DOWN, _, :process, ^child1, :normal}
      assert_receive {:DOWN, _, :process, ^child2, :normal}
      assert_receive {:DOWN, _, :process, ^child3, :normal}
    end
  end

  describe "terminate_child/2" do
    test "terminates child with brutal kill" do
      children = [task_worker(shutdown: :brutal_kill)]
      {:ok, sup} = DynamicSupervisor.start_link(children, strategy: :one_for_one)

      fun = fn -> :timer.sleep(:infinity) end
      assert {:ok, child} = DynamicSupervisor.start_child(sup, [fun])

      Process.monitor(child)
      assert :ok = DynamicSupervisor.terminate_child(sup, child)
      assert_receive {:DOWN, _, :process, ^child, :killed}

      assert {:error, :not_found} = DynamicSupervisor.terminate_child(sup, child)
      assert %{workers: 0, active: 0} = DynamicSupervisor.count_children(sup)
    end

    test "terminates child with integer shutdown" do
      children = [task_worker(shutdown: 1000)]
      {:ok, sup} = DynamicSupervisor.start_link(children, strategy: :one_for_one)

      fun = fn -> :timer.sleep(:infinity) end
      assert {:ok, child} = DynamicSupervisor.start_child(sup, [fun])

      Process.monitor(child)
      assert :ok = DynamicSupervisor.terminate_child(sup, child)
      assert_receive {:DOWN, _, :process, ^child, :shutdown}

      assert {:error, :not_found} = DynamicSupervisor.terminate_child(sup, child)
      assert %{workers: 0, active: 0} = DynamicSupervisor.count_children(sup)
    end

    test "terminates restarting child" do
      children = [current_module_worker(restart: :permanent)]

      {:ok, sup} =
        DynamicSupervisor.start_link(children, strategy: :one_for_one, max_restarts: 100_000)

      assert {:ok, child} = DynamicSupervisor.start_child(sup, [:restart, :error])
      assert_kill(child, :shutdown)
      assert :ok = DynamicSupervisor.terminate_child(sup, child)

      assert {:error, :not_found} = DynamicSupervisor.terminate_child(sup, child)
      assert %{workers: 0, active: 0} = DynamicSupervisor.count_children(sup)
    end
  end

  defp sleepy_worker do
    %{id: Task, start: {Task, :start_link, [:timer, :sleep, [:infinity]]}}
  end

  defp task_worker(opts) do
    Supervisor.child_spec(%{id: Task, start: {Task, :start_link, []}}, opts)
  end

  defp current_module_worker(opts \\ []) do
    Supervisor.child_spec(%{id: __MODULE__, start: {__MODULE__, :start_link, []}}, opts)
  end

  defp assert_kill(pid, reason) do
    ref = Process.monitor(pid)
    Process.exit(pid, reason)
    assert_receive {:DOWN, ^ref, _, _, _}
  end
end
