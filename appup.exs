{
  ~c"0.1.25",
  [
    {~c"0.1.24",
     [
       # An update only reaches processes in the supervision tree. An unsupervised
       # process keeps running the old code.
       #
       # add_module comes first and delete_module last, but changed modules are not
       # ordered by dependency. Reorder them, or add DepMods, where one depends on
       # another.
       #
       # Database.Queue: added by this transition.
       {:add_module, Database.Queue},
       # Database.Writer: no behaviour. The code is replaced without suspending anything.
       {:load_module, Database.Writer},
       # Discord.Broadcaster: behaviour GenServer. The update suspends the process and
       # calls code_change/3 with Extra = []. Replace [] if the migration needs data.
       {:update, Discord.Broadcaster, {:advanced, []}},
       # Discord.Database: no behaviour. The code is replaced without suspending
       # anything.
       {:load_module, Discord.Database},
       # Discord.Messages: removed in this release (embeds extracted into
       # Discord.Embeds); delete the old module from the running system.
       {:delete_module, Discord.Messages},
       # Discord.Embeds: new module extracted from Discord; add it.
       {:add_module, Discord.Embeds},
       # ESI: no behaviour. The code is replaced without suspending anything.
       {:load_module, ESI},
       # Etag.Database: no behaviour. The code is replaced without suspending anything.
       {:load_module, Etag.Database},
       # Market: no behaviour. The code is replaced without suspending anything.
       {:load_module, Market},
       # Market.Database: no behaviour. The code is replaced without suspending anything.
       {:load_module, Market.Database},
       # Marketmailer.Application: behaviour Application. release_handler migrates no
       # state for it, so the code is replaced without suspending anything. If the module
       # holds state that changes shape, load_module is not enough.
       {:load_module, Marketmailer.Application},
       # Marketmailer.Log.Format: no behaviour. The code is replaced without suspending
       # anything.
       {:load_module, Marketmailer.Log.Format},
       # Marketmailer.PageWorker: behaviour GenServer. The update suspends the process
       # and calls code_change/3 with Extra = []. Replace [] if the migration needs data.
       {:update, Marketmailer.PageWorker, {:advanced, []}},
       # Marketmailer.RegionManager: behaviour GenServer. The update suspends the process
       # and calls code_change/3 with Extra = []. Replace [] if the migration needs data.
       {:update, Marketmailer.RegionManager, {:advanced, []}}
     ]},
    {~c"0.1.23",
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
       # Discord.Messages: no behaviour. The code is replaced without suspending
       # anything.
       {:load_module, Discord.Messages},
       # Marketmailer.Log.Format: no behaviour. The code is replaced without suspending
       # anything.
       {:load_module, Marketmailer.Log.Format},
       # Marketmailer.RegionManager: behaviour GenServer. The update suspends the process
       # and calls code_change/3 with Extra = []. Replace [] if the migration needs data.
       {:update, Marketmailer.RegionManager, {:advanced, []}}
     ]},
    {~c"0.1.22",
     [
       # An update only reaches processes in the supervision tree. An unsupervised
       # process keeps running the old code.
       #
       # add_module comes first and delete_module last, but changed modules are not
       # ordered by dependency. Reorder them, or add DepMods, where one depends on
       # another.
       #
       # Discord.Consumer: behaviour Nostrum.Consumer. release_handler migrates no state
       # for it, so the code is replaced without suspending anything. If the module holds
       # state that changes shape, load_module is not enough.
       {:load_module, Discord.Consumer},
       # Discord.Database: no behaviour. The code is replaced without suspending
       # anything.
       {:load_module, Discord.Database},
       # Discord.Messages: no behaviour. The code is replaced without suspending
       # anything.
       {:load_module, Discord.Messages},
       # Etag.Database: no behaviour. The code is replaced without suspending anything.
       {:load_module, Etag.Database},
       # Janice.ChartPool: behaviour GenServer. The update suspends the process and calls
       # code_change/3 with Extra = []. Replace [] if the migration needs data.
       {:update, Janice.ChartPool, {:advanced, []}},
       # Marketmailer.Application: behaviour Application. release_handler migrates no
       # state for it, so the code is replaced without suspending anything. If the module
       # holds state that changes shape, load_module is not enough.
       {:load_module, Marketmailer.Application},
       # Marketmailer.Log: no behaviour. The code is replaced without suspending
       # anything.
       {:load_module, Marketmailer.Log},
       # Marketmailer.Log.Format: no behaviour. The code is replaced without suspending
       # anything.
       {:load_module, Marketmailer.Log.Format},
       # MarketmailerWeb.Router: behaviours Plug, Phoenix.VerifiedRoutes. release_handler
       # migrates no state for it, so the code is replaced without suspending anything.
       # If the module holds state that changes shape, load_module is not enough.
       {:load_module, MarketmailerWeb.Router},
       # Mix.Tasks.Chartdb: behaviour Mix.Task. release_handler migrates no state for it,
       # so the code is replaced without suspending anything. If the module holds state
       # that changes shape, load_module is not enough.
       {:load_module, Mix.Tasks.Chartdb},
       # Mix.Tasks.Sde.Import: behaviour Mix.Task. release_handler migrates no state for
       # it, so the code is replaced without suspending anything. If the module holds
       # state that changes shape, load_module is not enough.
       {:load_module, Mix.Tasks.Sde.Import},
       # Mix.Tasks.Test.Safe: removed by this transition. delete_module purges the module
       # and loads nothing, so never use it for a module the target build still has.
       {:delete_module, Mix.Tasks.Test.Safe}
     ]},
    {~c"0.1.21",
     [
       {:load_module, Database.Writer},
       {:update, Discord.Broadcaster, {:advanced, []}},
       {:load_module, Discord.Database},
       {:load_module, Discord.Messages},
       {:load_module, Etag.Database},
       {:load_module, Marketmailer.Application},
       {:load_module, Marketmailer.Log.Format},
       {:update, Marketmailer.RegionManager, {:advanced, []}},
       {:load_module, Mix.Tasks.Sde.Import}
     ]},
    {~c"0.1.20",
     [
       {:load_module, Discord.Messages},
       {:load_module, Marketmailer.Log.Format}
     ]},
    {~c"0.1.19",
     [
       {:load_module, Discord.Messages},
       {:load_module, Marketmailer.Log.Format}
     ]},
    {~c"0.1.18",
     [
       {:update, Discord.Broadcaster, {:advanced, []}},
       {:load_module, Discord.Consumer},
       {:load_module, Discord.Messages},
       {:load_module, Marketmailer.Log.Format}
     ]},
    {~c"0.1.17",
     [
       {:load_module, Discord.Messages},
       {:load_module, Marketmailer.Log.Format}
     ]},
    {~c"0.1.16",
     [
       {:load_module, Discord.Messages},
       {:load_module, Marketmailer.Log.Format}
     ]},
  ],
  [
    {~c"0.1.24",
     [
       # An update only reaches processes in the supervision tree. An unsupervised
       # process keeps running the old code.
       #
       # add_module comes first and delete_module last, but changed modules are not
       # ordered by dependency. Reorder them, or add DepMods, where one depends on
       # another.
       #
       # Database.Writer: no behaviour. The code is replaced without suspending anything.
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
       # ESI: no behaviour. The code is replaced without suspending anything.
       {:load_module, ESI},
       # Etag.Database: no behaviour. The code is replaced without suspending anything.
       {:load_module, Etag.Database},
       # Market: no behaviour. The code is replaced without suspending anything.
       {:load_module, Market},
       # Market.Database: no behaviour. The code is replaced without suspending anything.
       {:load_module, Market.Database},
       # Marketmailer.Application: behaviour Application. release_handler migrates no
       # state for it, so the code is replaced without suspending anything. If the module
       # holds state that changes shape, load_module is not enough.
       {:load_module, Marketmailer.Application},
       # Marketmailer.Log.Format: no behaviour. The code is replaced without suspending
       # anything.
       {:load_module, Marketmailer.Log.Format},
       # Marketmailer.PageWorker: behaviour GenServer. The update suspends the process
       # and calls code_change/3 with Extra = []. Replace [] if the migration needs data.
       {:update, Marketmailer.PageWorker, {:advanced, []}},
       # Marketmailer.RegionManager: behaviour GenServer. The update suspends the process
       # and calls code_change/3 with Extra = []. Replace [] if the migration needs data.
       {:update, Marketmailer.RegionManager, {:advanced, []}},
       # Database.Queue: removed by this transition. delete_module purges the module and
       # loads nothing, so never use it for a module the target build still has.
       {:delete_module, Database.Queue}
     ]},
    {~c"0.1.23",
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
       # Discord.Messages: no behaviour. The code is replaced without suspending
       # anything.
       {:load_module, Discord.Messages},
       # Marketmailer.Log.Format: no behaviour. The code is replaced without suspending
       # anything.
       {:load_module, Marketmailer.Log.Format},
       # Marketmailer.RegionManager: behaviour GenServer. The update suspends the process
       # and calls code_change/3 with Extra = []. Replace [] if the migration needs data.
       {:update, Marketmailer.RegionManager, {:advanced, []}}
     ]},
    {~c"0.1.22",
     [
       # An update only reaches processes in the supervision tree. An unsupervised
       # process keeps running the old code.
       #
       # add_module comes first and delete_module last, but changed modules are not
       # ordered by dependency. Reorder them, or add DepMods, where one depends on
       # another.
       #
       # Mix.Tasks.Test.Safe: added by this transition.
       {:add_module, Mix.Tasks.Test.Safe},
       # Discord.Consumer: behaviour Nostrum.Consumer. release_handler migrates no state
       # for it, so the code is replaced without suspending anything. If the module holds
       # state that changes shape, load_module is not enough.
       {:load_module, Discord.Consumer},
       # Discord.Database: no behaviour. The code is replaced without suspending
       # anything.
       {:load_module, Discord.Database},
       # Discord.Messages: no behaviour. The code is replaced without suspending
       # anything.
       {:load_module, Discord.Messages},
       # Etag.Database: no behaviour. The code is replaced without suspending anything.
       {:load_module, Etag.Database},
       # Janice.ChartPool: behaviour GenServer. The update suspends the process and calls
       # code_change/3 with Extra = []. Replace [] if the migration needs data.
       {:update, Janice.ChartPool, {:advanced, []}},
       # Marketmailer.Application: behaviour Application. release_handler migrates no
       # state for it, so the code is replaced without suspending anything. If the module
       # holds state that changes shape, load_module is not enough.
       {:load_module, Marketmailer.Application},
       # Marketmailer.Log: no behaviour. The code is replaced without suspending
       # anything.
       {:load_module, Marketmailer.Log},
       # Marketmailer.Log.Format: no behaviour. The code is replaced without suspending
       # anything.
       {:load_module, Marketmailer.Log.Format},
       # MarketmailerWeb.Router: behaviours Plug, Phoenix.VerifiedRoutes. release_handler
       # migrates no state for it, so the code is replaced without suspending anything.
       # If the module holds state that changes shape, load_module is not enough.
       {:load_module, MarketmailerWeb.Router},
       # Mix.Tasks.Chartdb: behaviour Mix.Task. release_handler migrates no state for it,
       # so the code is replaced without suspending anything. If the module holds state
       # that changes shape, load_module is not enough.
       {:load_module, Mix.Tasks.Chartdb},
       # Mix.Tasks.Sde.Import: behaviour Mix.Task. release_handler migrates no state for
       # it, so the code is replaced without suspending anything. If the module holds
       # state that changes shape, load_module is not enough.
       {:load_module, Mix.Tasks.Sde.Import}
     ]},
    {~c"0.1.21",
     [
       {:update, Database.Writer, {:advanced, []}},
       {:update, Discord.Broadcaster, {:advanced, []}},
       {:load_module, Discord.Database},
       {:load_module, Discord.Messages},
       {:load_module, Etag.Database},
       {:load_module, Marketmailer.Application},
       {:load_module, Marketmailer.Log.Format},
       {:update, Marketmailer.RegionManager, {:advanced, []}},
       {:load_module, Mix.Tasks.Sde.Import}
     ]},
    {~c"0.1.20",
     [
       {:load_module, Discord.Messages},
       {:load_module, Marketmailer.Log.Format}
     ]},
    {~c"0.1.19",
     [
       {:load_module, Discord.Messages},
       {:load_module, Marketmailer.Log.Format}
     ]},
    {~c"0.1.18",
     [
       {:update, Discord.Broadcaster, {:advanced, []}},
       {:load_module, Discord.Consumer},
       {:load_module, Discord.Messages},
       {:load_module, Marketmailer.Log.Format}
     ]},
    {~c"0.1.17",
     [
       {:load_module, Discord.Messages},
       {:load_module, Marketmailer.Log.Format}
     ]},
    {~c"0.1.16",
     [
       {:load_module, Discord.Messages},
       {:load_module, Marketmailer.Log.Format}
     ]},
  ]
}
