defmodule AshReplicant.Test.UnadmittedPipeline do
  @moduledoc false

  @load_count_key {__MODULE__, :load_count}
  @start_options_key {__MODULE__, :start_options_called}

  @on_load :record_load

  def record_load do
    :persistent_term.put(@load_count_key, :persistent_term.get(@load_count_key, 0) + 1)
    :ok
  end

  def start_options do
    :persistent_term.put(@start_options_key, true)
    :not_configured
  end
end

defmodule AshReplicant.Test.AdmittedPipeline do
  @moduledoc false

  use AshReplicant.Pipeline,
    otp_app: :ash_replicant,
    sink: AshReplicant.Test.Marquee.Sink
end
