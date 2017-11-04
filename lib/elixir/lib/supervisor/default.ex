defmodule Supervisor.Default do
  @moduledoc false

  def init({module, children, opts}) do
    module.init(children, opts)
  end
end
