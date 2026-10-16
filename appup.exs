{
  ~c"0.1.22",
  [
    {~c"0.1.21",
     [
       # An update only reaches processes in the supervision tree. An unsupervised
       # process keeps running the old code.
       #
       # add_module comes first and delete_module last, but changed modules are not
       # ordered by dependency. Reorder them, or add DepMods, where one depends on
       # another.
       #
       # Database.Writer: no behaviour. The code is replaced without suspending anything.
       #
       # WARNING: Database.Writer changed behaviour role in this transition:
       #   was: a process with migratable state, through code_change/3
       #   now: a module with no supervisor or process behaviour
       # The instruction suits the target code, but the running process was started by
       # the current code. Decide what should happen to that process.
       {:load_module, Database.Writer},
       # Discord.Broadcaster: behaviour GenServer. The update suspends the process and
       # calls code_change/3 with Extra = []. Replace [] if the migration needs data.
       {:update, Discord.Broadcaster, {:advanced, []}},
       # Discord.Database: no behaviour. The code is replaced without suspending
       # anything.
       {:load_module, Discord.Database},
       # Discord.Messages: no behaviour. The code is replaced without suspending
       # anything.
       {:load_module, Discord.Messages},
       # Etag.Database: no behaviour. The code is replaced without suspending anything.
       {:load_module, Etag.Database},
       # Marketmailer.Application: behaviour Application. release_handler migrates no
       # state for it, so the code is replaced without suspending anything. If the module
       # holds state that changes shape, load_module is not enough.
       {:load_module, Marketmailer.Application},
       # Marketmailer.Log.Format: no behaviour. The code is replaced without suspending
       # anything.
       {:load_module, Marketmailer.Log.Format},
       # Marketmailer.RegionManager: behaviour GenServer. The update suspends the process
       # and calls code_change/3 with Extra = []. Replace [] if the migration needs data.
       {:update, Marketmailer.RegionManager, {:advanced, []}},
       # Mix.Tasks.Sde.Import: behaviour Mix.Task. release_handler migrates no state for
       # it, so the code is replaced without suspending anything. If the module holds
       # state that changes shape, load_module is not enough.
       {:load_module, Mix.Tasks.Sde.Import}
     ]},
    {~c"0.1.20",
     [
       # add_module comes first and delete_module last, but changed modules are not
       # ordered by dependency. Reorder them, or add DepMods, where one depends on
       # another.
       #
       # Discord.Messages: no behaviour. The code is replaced without suspending
       # anything.
       {:load_module, Discord.Messages},
       # Marketmailer.Log.Format: no behaviour. The code is replaced without suspending
       # anything.
       {:load_module, Marketmailer.Log.Format}
     ]},
    {~c"0.1.19",
     [
       # add_module comes first and delete_module last, but changed modules are not
       # ordered by dependency. Reorder them, or add DepMods, where one depends on
       # another.
       #
       # Discord.Messages: no behaviour. The code is replaced without suspending
       # anything.
       {:load_module, Discord.Messages},
       # Marketmailer.Log.Format: no behaviour. The code is replaced without suspending
       # anything.
       {:load_module, Marketmailer.Log.Format}
     ]},
    {~c"0.1.18",
     [
       # An update only reaches processes in the supervision tree. An unsupervised
       # process keeps running the old code.
       #
       # add_module comes first and delete_module last, but changed modules are not
       # ordered by dependency. Reorder them, or add DepMods, where one depends on
       # another.
       #
       # Discord.Broadcaster: behaviour GenServer. The update suspends the process and
       # calls code_change/3 with Extra = []. Replace [] if the migration needs data.
       {:update, Discord.Broadcaster, {:advanced, []}},
       # Discord.Consumer: behaviour Nostrum.Consumer. release_handler migrates no state
       # for it, so the code is replaced without suspending anything. If the module holds
       # state that changes shape, load_module is not enough.
       {:load_module, Discord.Consumer},
       # Discord.Messages: no behaviour. The code is replaced without suspending
       # anything.
       {:load_module, Discord.Messages},
       # Marketmailer.Log.Format: no behaviour. The code is replaced without suspending
       # anything.
       {:load_module, Marketmailer.Log.Format}
     ]},
    {~c"0.1.17",
     [
       # add_module comes first and delete_module last, but changed modules are not
       # ordered by dependency. Reorder them, or add DepMods, where one depends on
       # another.
       #
       # Discord.Messages: no behaviour. The code is replaced without suspending
       # anything.
       {:load_module, Discord.Messages},
       # Marketmailer.Log.Format: no behaviour. The code is replaced without suspending
       # anything.
       {:load_module, Marketmailer.Log.Format}
     ]},
    {~c"0.1.16",
     [
       # add_module comes first and delete_module last, but changed modules are not
       # ordered by dependency. Reorder them, or add DepMods, where one depends on
       # another.
       #
       # Discord.Messages: no behaviour. The code is replaced without suspending
       # anything.
       {:load_module, Discord.Messages},
       # Marketmailer.Log.Format: no behaviour. The code is replaced without suspending
       # anything.
       {:load_module, Marketmailer.Log.Format}
     ]},
  ],
  [
    {~c"0.1.21",
     [
       # An update only reaches processes in the supervision tree. An unsupervised
       # process keeps running the old code.
       #
       # add_module comes first and delete_module last, but changed modules are not
       # ordered by dependency. Reorder them, or add DepMods, where one depends on
       # another.
       #
       # Database.Writer: behaviour GenServer. The update suspends the process and calls
       # code_change/3 with Extra = []. Replace [] if the migration needs data.
       #
       # WARNING: Database.Writer changed behaviour role in this transition:
       #   was: a module with no supervisor or process behaviour
       #   now: a process with migratable state, through code_change/3
       # The instruction suits the target code, but the running process was started by
       # the current code. Decide what should happen to that process.
       {:update, Database.Writer, {:advanced, []}},
       # Discord.Broadcaster: behaviour GenServer. The update suspends the process and
       # calls code_change/3 with Extra = []. Replace [] if the migration needs data.
       {:update, Discord.Broadcaster, {:advanced, []}},
       # Discord.Database: no behaviour. The code is replaced without suspending
       # anything.
       {:load_module, Discord.Database},
       # Discord.Messages: no behaviour. The code is replaced without suspending
       # anything.
       {:load_module, Discord.Messages},
       # Etag.Database: no behaviour. The code is replaced without suspending anything.
       {:load_module, Etag.Database},
       # Marketmailer.Application: behaviour Application. release_handler migrates no
       # state for it, so the code is replaced without suspending anything. If the module
       # holds state that changes shape, load_module is not enough.
       {:load_module, Marketmailer.Application},
       # Marketmailer.Log.Format: no behaviour. The code is replaced without suspending
       # anything.
       {:load_module, Marketmailer.Log.Format},
       # Marketmailer.RegionManager: behaviour GenServer. The update suspends the process
       # and calls code_change/3 with Extra = []. Replace [] if the migration needs data.
       {:update, Marketmailer.RegionManager, {:advanced, []}},
       # Mix.Tasks.Sde.Import: behaviour Mix.Task. release_handler migrates no state for
       # it, so the code is replaced without suspending anything. If the module holds
       # state that changes shape, load_module is not enough.
       {:load_module, Mix.Tasks.Sde.Import}
     ]},
    {~c"0.1.20",
     [
       # add_module comes first and delete_module last, but changed modules are not
       # ordered by dependency. Reorder them, or add DepMods, where one depends on
       # another.
       #
       # Discord.Messages: no behaviour. The code is replaced without suspending
       # anything.
       {:load_module, Discord.Messages},
       # Marketmailer.Log.Format: no behaviour. The code is replaced without suspending
       # anything.
       {:load_module, Marketmailer.Log.Format}
     ]},
    {~c"0.1.19",
     [
       # add_module comes first and delete_module last, but changed modules are not
       # ordered by dependency. Reorder them, or add DepMods, where one depends on
       # another.
       #
       # Discord.Messages: no behaviour. The code is replaced without suspending
       # anything.
       {:load_module, Discord.Messages},
       # Marketmailer.Log.Format: no behaviour. The code is replaced without suspending
       # anything.
       {:load_module, Marketmailer.Log.Format}
     ]},
    {~c"0.1.18",
     [
       # An update only reaches processes in the supervision tree. An unsupervised
       # process keeps running the old code.
       #
       # add_module comes first and delete_module last, but changed modules are not
       # ordered by dependency. Reorder them, or add DepMods, where one depends on
       # another.
       #
       # Discord.Broadcaster: behaviour GenServer. The update suspends the process and
       # calls code_change/3 with Extra = []. Replace [] if the migration needs data.
       {:update, Discord.Broadcaster, {:advanced, []}},
       # Discord.Consumer: behaviour Nostrum.Consumer. release_handler migrates no state
       # for it, so the code is replaced without suspending anything. If the module holds
       # state that changes shape, load_module is not enough.
       {:load_module, Discord.Consumer},
       # Discord.Messages: no behaviour. The code is replaced without suspending
       # anything.
       {:load_module, Discord.Messages},
       # Marketmailer.Log.Format: no behaviour. The code is replaced without suspending
       # anything.
       {:load_module, Marketmailer.Log.Format}
     ]},
    {~c"0.1.17",
     [
       # add_module comes first and delete_module last, but changed modules are not
       # ordered by dependency. Reorder them, or add DepMods, where one depends on
       # another.
       #
       # Discord.Messages: no behaviour. The code is replaced without suspending
       # anything.
       {:load_module, Discord.Messages},
       # Marketmailer.Log.Format: no behaviour. The code is replaced without suspending
       # anything.
       {:load_module, Marketmailer.Log.Format}
     ]},
    {~c"0.1.16",
     [
       # add_module comes first and delete_module last, but changed modules are not
       # ordered by dependency. Reorder them, or add DepMods, where one depends on
       # another.
       #
       # Discord.Messages: no behaviour. The code is replaced without suspending
       # anything.
       {:load_module, Discord.Messages},
       # Marketmailer.Log.Format: no behaviour. The code is replaced without suspending
       # anything.
       {:load_module, Marketmailer.Log.Format}
     ]},
  ]
}
