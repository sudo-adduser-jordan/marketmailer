{
  ~c"0.1.13",
  [
    {~c"0.1.12",
     [
       # add_module comes first and delete_module last, but changed modules are not
       # ordered by dependency. Reorder them, or add DepMods, where one depends on
       # another.
       #
       # MarketmailerWeb.DashboardAuth: added by this transition.
       {:add_module, MarketmailerWeb.DashboardAuth},
       # MarketmailerWeb.Endpoint: added by this transition.
       {:add_module, MarketmailerWeb.Endpoint},
       # MarketmailerWeb.ErrorHTML: added by this transition.
       {:add_module, MarketmailerWeb.ErrorHTML},
       # MarketmailerWeb.Router: added by this transition.
       {:add_module, MarketmailerWeb.Router},
       # MarketmailerWeb.Router.Helpers: added by this transition.
       {:add_module, MarketmailerWeb.Router.Helpers},
       # MarketmailerWeb.Telemetry: added by this transition.
       {:add_module, MarketmailerWeb.Telemetry},
       # Discord.Consumer: behaviour Nostrum.Consumer. release_handler migrates no state
       # for it, so the code is replaced without suspending anything. If the module holds
       # state that changes shape, load_module is not enough.
       {:load_module, Discord.Consumer},
       # Discord.Messages: no behaviour. The code is replaced without suspending
       # anything.
       {:load_module, Discord.Messages},
       # Marketmailer.Application: behaviour Application. release_handler migrates no
       # state for it, so the code is replaced without suspending anything. If the module
       # holds state that changes shape, load_module is not enough.
       {:load_module, Marketmailer.Application},
       # Marketmailer.Log.Format: no behaviour. The code is replaced without suspending
       # anything.
       {:load_module, Marketmailer.Log.Format}
     ]},
    {~c"0.1.11",
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
       # Market.Database: no behaviour. The code is replaced without suspending anything.
       {:load_module, Market.Database},
       # Marketmailer.Log.Format: no behaviour. The code is replaced without suspending
       # anything.
       {:load_module, Marketmailer.Log.Format}
     ]},
    {~c"0.1.10",
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
    {~c"0.1.9",
     [
       # add_module comes first and delete_module last, but changed modules are not
       # ordered by dependency. Reorder them, or add DepMods, where one depends on
       # another.
       #
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
    {~c"0.1.8",
     [
       # add_module comes first and delete_module last, but changed modules are not
       # ordered by dependency. Reorder them, or add DepMods, where one depends on
       # another.
       #
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
    {~c"0.1.7",
     [
       # An update only reaches processes in the supervision tree. An unsupervised
       # process keeps running the old code.
       #
       # add_module comes first and delete_module last, but changed modules are not
       # ordered by dependency. Reorder them, or add DepMods, where one depends on
       # another.
       #
       # Janice.ChartPool: added by this transition.
       {:add_module, Janice.ChartPool},
       # Janice.Playwright: behaviour Janice.Capture. release_handler migrates no state
       # for it, so the code is replaced without suspending anything. If the module holds
       # state that changes shape, load_module is not enough.
       {:load_module, Janice.Playwright},
       # Janice.Supervisor: behaviour Supervisor. The update re-runs init/1 and updates
       # the child specs. The children themselves are not upgraded; give them their own
       # instructions.
       {:update, Janice.Supervisor, :supervisor},
       # Marketmailer.Application: behaviour Application. release_handler migrates no
       # state for it, so the code is replaced without suspending anything. If the module
       # holds state that changes shape, load_module is not enough.
       {:load_module, Marketmailer.Application},
       # Marketmailer.Log.Format: no behaviour. The code is replaced without suspending
       # anything.
       {:load_module, Marketmailer.Log.Format},
       # Marketmailer.PageWorker: behaviour GenServer. The update suspends the process
       # and calls code_change/3 with Extra = []. Replace [] if the migration needs data.
       {:update, Marketmailer.PageWorker, {:advanced, []}}
     ]},
    {~c"0.1.6",
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
       # ESI: no behaviour. The code is replaced without suspending anything.
       {:load_module, ESI},
       # Market.Database: no behaviour. The code is replaced without suspending anything.
       {:load_module, Market.Database},
       # MarketView: no behaviour. The code is replaced without suspending anything.
       {:load_module, MarketView},
       # Marketmailer.Application: behaviour Application. release_handler migrates no
       # state for it, so the code is replaced without suspending anything. If the module
       # holds state that changes shape, load_module is not enough.
       {:load_module, Marketmailer.Application},
       # Marketmailer.Log.Format: no behaviour. The code is replaced without suspending
       # anything.
       {:load_module, Marketmailer.Log.Format},
       # Universe.Database: no behaviour. The code is replaced without suspending
       # anything.
       {:load_module, Universe.Database}
     ]},
    {~c"0.1.5",
     [
       # An update only reaches processes in the supervision tree. An unsupervised
       # process keeps running the old code.
       #
       # add_module comes first and delete_module last, but changed modules are not
       # ordered by dependency. Reorder them, or add DepMods, where one depends on
       # another.
       #
       # ESI.Ids: added by this transition.
       {:add_module, ESI.Ids},
       # Discord.Broadcaster: behaviour GenServer. The update suspends the process and
       # calls code_change/3 with Extra = []. Replace [] if the migration needs data.
       {:update, Discord.Broadcaster, {:advanced, []}},
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
       # Market.Database: no behaviour. The code is replaced without suspending anything.
       {:load_module, Market.Database},
       # Market.DbWriter: behaviour GenServer. The update suspends the process and calls
       # code_change/3 with Extra = []. Replace [] if the migration needs data.
       {:update, Market.DbWriter, {:advanced, []}},
       # Marketmailer.Log.Format: no behaviour. The code is replaced without suspending
       # anything.
       {:load_module, Marketmailer.Log.Format},
       # Marketmailer.PageWorker: behaviour GenServer. The update suspends the process
       # and calls code_change/3 with Extra = []. Replace [] if the migration needs data.
       {:update, Marketmailer.PageWorker, {:advanced, []}},
       # Universe.Database: no behaviour. The code is replaced without suspending
       # anything.
       {:load_module, Universe.Database}
     ]},
    {~c"0.1.4",
     [
       # An update only reaches processes in the supervision tree. An unsupervised
       # process keeps running the old code.
       #
       # add_module comes first and delete_module last, but changed modules are not
       # ordered by dependency. Reorder them, or add DepMods, where one depends on
       # another.
       #
       # Market.DbWriter: added by this transition.
       {:add_module, Market.DbWriter},
       # Discord.Database: no behaviour. The code is replaced without suspending
       # anything.
       {:load_module, Discord.Database},
       # Etag.Database: no behaviour. The code is replaced without suspending anything.
       {:load_module, Etag.Database},
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
       # Universe.Database: no behaviour. The code is replaced without suspending
       # anything.
       {:load_module, Universe.Database}
     ]},
    {~c"0.1.3",
     [
       # add_module comes first and delete_module last, but changed modules are not
       # ordered by dependency. Reorder them, or add DepMods, where one depends on
       # another.
       #
       # ESI: no behaviour. The code is replaced without suspending anything.
       {:load_module, ESI},
       # Marketmailer.Log.Format: no behaviour. The code is replaced without suspending
       # anything.
       {:load_module, Marketmailer.Log.Format}
     ]},
    {~c"0.1.2",
     [
       # An update only reaches processes in the supervision tree. An unsupervised
       # process keeps running the old code.
       #
       # add_module comes first and delete_module last, but changed modules are not
       # ordered by dependency. Reorder them, or add DepMods, where one depends on
       # another.
       #
       # Marketmailer.Log.Format: no behaviour. The code is replaced without suspending
       # anything.
       {:load_module, Marketmailer.Log.Format},
       # Marketmailer.PageWorker: behaviour GenServer. The update suspends the process
       # and calls code_change/3 with Extra = []. Replace [] if the migration needs data.
       {:update, Marketmailer.PageWorker, {:advanced, []}}
     ]},
    {~c"0.1.1",
     [
       # An update only reaches processes in the supervision tree. An unsupervised
       # process keeps running the old code.
       #
       # add_module comes first and delete_module last, but changed modules are not
       # ordered by dependency. Reorder them, or add DepMods, where one depends on
       # another.
       #
       # Mix.Tasks.Chartdb: added by this transition.
       {:add_module, Mix.Tasks.Chartdb},
       # Discord.Broadcaster: behaviour GenServer. The update suspends the process and
       # calls code_change/3 with Extra = []. Replace [] if the migration needs data.
       {:update, Discord.Broadcaster, {:advanced, []}},
       # Discord.Consumer: behaviour Nostrum.Consumer. release_handler migrates no state
       # for it, so the code is replaced without suspending anything. If the module holds
       # state that changes shape, load_module is not enough.
       {:load_module, Discord.Consumer},
       # Etag.Database: no behaviour. The code is replaced without suspending anything.
       {:load_module, Etag.Database},
       # Janice.Capture: no behaviour. The code is replaced without suspending anything.
       {:load_module, Janice.Capture},
       # Marketmailer.Log.Format: no behaviour. The code is replaced without suspending
       # anything.
       {:load_module, Marketmailer.Log.Format}
     ]}
  ],
  [
    {~c"0.1.12",
     [
       # add_module comes first and delete_module last, but changed modules are not
       # ordered by dependency. Reorder them, or add DepMods, where one depends on
       # another.
       #
       # Discord.Consumer: behaviour Nostrum.Consumer. release_handler migrates no state
       # for it, so the code is replaced without suspending anything. If the module holds
       # state that changes shape, load_module is not enough.
       {:load_module, Discord.Consumer},
       # Discord.Messages: no behaviour. The code is replaced without suspending
       # anything.
       {:load_module, Discord.Messages},
       # Marketmailer.Application: behaviour Application. release_handler migrates no
       # state for it, so the code is replaced without suspending anything. If the module
       # holds state that changes shape, load_module is not enough.
       {:load_module, Marketmailer.Application},
       # Marketmailer.Log.Format: no behaviour. The code is replaced without suspending
       # anything.
       {:load_module, Marketmailer.Log.Format},
       # MarketmailerWeb.DashboardAuth: removed by this transition. delete_module purges
       # the module and loads nothing, so never use it for a module the target build
       # still has.
       {:delete_module, MarketmailerWeb.DashboardAuth},
       # MarketmailerWeb.Endpoint: removed by this transition. delete_module purges the
       # module and loads nothing, so never use it for a module the target build still
       # has.
       {:delete_module, MarketmailerWeb.Endpoint},
       # MarketmailerWeb.ErrorHTML: removed by this transition. delete_module purges the
       # module and loads nothing, so never use it for a module the target build still
       # has.
       {:delete_module, MarketmailerWeb.ErrorHTML},
       # MarketmailerWeb.Router: removed by this transition. delete_module purges the
       # module and loads nothing, so never use it for a module the target build still
       # has.
       {:delete_module, MarketmailerWeb.Router},
       # MarketmailerWeb.Router.Helpers: removed by this transition. delete_module purges
       # the module and loads nothing, so never use it for a module the target build
       # still has.
       {:delete_module, MarketmailerWeb.Router.Helpers},
       # MarketmailerWeb.Telemetry: removed by this transition. delete_module purges the
       # module and loads nothing, so never use it for a module the target build still
       # has.
       {:delete_module, MarketmailerWeb.Telemetry}
     ]},
    {~c"0.1.11",
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
       # Market.Database: no behaviour. The code is replaced without suspending anything.
       {:load_module, Market.Database},
       # Marketmailer.Log.Format: no behaviour. The code is replaced without suspending
       # anything.
       {:load_module, Marketmailer.Log.Format}
     ]},
    {~c"0.1.10",
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
    {~c"0.1.9",
     [
       # add_module comes first and delete_module last, but changed modules are not
       # ordered by dependency. Reorder them, or add DepMods, where one depends on
       # another.
       #
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
    {~c"0.1.8",
     [
       # add_module comes first and delete_module last, but changed modules are not
       # ordered by dependency. Reorder them, or add DepMods, where one depends on
       # another.
       #
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
    {~c"0.1.7",
     [
       # An update only reaches processes in the supervision tree. An unsupervised
       # process keeps running the old code.
       #
       # add_module comes first and delete_module last, but changed modules are not
       # ordered by dependency. Reorder them, or add DepMods, where one depends on
       # another.
       #
       # Janice.Playwright: behaviour Janice.Capture. release_handler migrates no state
       # for it, so the code is replaced without suspending anything. If the module holds
       # state that changes shape, load_module is not enough.
       {:load_module, Janice.Playwright},
       # Janice.Supervisor: behaviour Supervisor. The update re-runs init/1 and updates
       # the child specs. The children themselves are not upgraded; give them their own
       # instructions.
       {:update, Janice.Supervisor, :supervisor},
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
       # Janice.ChartPool: removed by this transition. delete_module purges the module
       # and loads nothing, so never use it for a module the target build still has.
       {:delete_module, Janice.ChartPool}
     ]},
    {~c"0.1.6",
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
       # ESI: no behaviour. The code is replaced without suspending anything.
       {:load_module, ESI},
       # Market.Database: no behaviour. The code is replaced without suspending anything.
       {:load_module, Market.Database},
       # MarketView: no behaviour. The code is replaced without suspending anything.
       {:load_module, MarketView},
       # Marketmailer.Application: behaviour Application. release_handler migrates no
       # state for it, so the code is replaced without suspending anything. If the module
       # holds state that changes shape, load_module is not enough.
       {:load_module, Marketmailer.Application},
       # Marketmailer.Log.Format: no behaviour. The code is replaced without suspending
       # anything.
       {:load_module, Marketmailer.Log.Format},
       # Universe.Database: no behaviour. The code is replaced without suspending
       # anything.
       {:load_module, Universe.Database}
     ]},
    {~c"0.1.5",
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
       # Discord.Database: no behaviour. The code is replaced without suspending
       # anything.
       {:load_module, Discord.Database},
       # Discord.Messages: no behaviour. The code is replaced without suspending
       # anything.
       {:load_module, Discord.Messages},
       # Etag.Database: no behaviour. The code is replaced without suspending anything.
       {:load_module, Etag.Database},
       # Market.Database: no behaviour. The code is replaced without suspending anything.
       {:load_module, Market.Database},
       # Market.DbWriter: behaviour GenServer. The update suspends the process and calls
       # code_change/3 with Extra = []. Replace [] if the migration needs data.
       {:update, Market.DbWriter, {:advanced, []}},
       # Marketmailer.Log.Format: no behaviour. The code is replaced without suspending
       # anything.
       {:load_module, Marketmailer.Log.Format},
       # Marketmailer.PageWorker: behaviour GenServer. The update suspends the process
       # and calls code_change/3 with Extra = []. Replace [] if the migration needs data.
       {:update, Marketmailer.PageWorker, {:advanced, []}},
       # Universe.Database: no behaviour. The code is replaced without suspending
       # anything.
       {:load_module, Universe.Database},
       # ESI.Ids: removed by this transition. delete_module purges the module and loads
       # nothing, so never use it for a module the target build still has.
       {:delete_module, ESI.Ids}
     ]},
    {~c"0.1.4",
     [
       # An update only reaches processes in the supervision tree. An unsupervised
       # process keeps running the old code.
       #
       # add_module comes first and delete_module last, but changed modules are not
       # ordered by dependency. Reorder them, or add DepMods, where one depends on
       # another.
       #
       # Discord.Database: no behaviour. The code is replaced without suspending
       # anything.
       {:load_module, Discord.Database},
       # Etag.Database: no behaviour. The code is replaced without suspending anything.
       {:load_module, Etag.Database},
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
       # Universe.Database: no behaviour. The code is replaced without suspending
       # anything.
       {:load_module, Universe.Database},
       # Market.DbWriter: removed by this transition. delete_module purges the module and
       # loads nothing, so never use it for a module the target build still has.
       {:delete_module, Market.DbWriter}
     ]},
    {~c"0.1.3",
     [
       # add_module comes first and delete_module last, but changed modules are not
       # ordered by dependency. Reorder them, or add DepMods, where one depends on
       # another.
       #
       # ESI: no behaviour. The code is replaced without suspending anything.
       {:load_module, ESI},
       # Marketmailer.Log.Format: no behaviour. The code is replaced without suspending
       # anything.
       {:load_module, Marketmailer.Log.Format}
     ]},
    {~c"0.1.2",
     [
       # An update only reaches processes in the supervision tree. An unsupervised
       # process keeps running the old code.
       #
       # add_module comes first and delete_module last, but changed modules are not
       # ordered by dependency. Reorder them, or add DepMods, where one depends on
       # another.
       #
       # Marketmailer.Log.Format: no behaviour. The code is replaced without suspending
       # anything.
       {:load_module, Marketmailer.Log.Format},
       # Marketmailer.PageWorker: behaviour GenServer. The update suspends the process
       # and calls code_change/3 with Extra = []. Replace [] if the migration needs data.
       {:update, Marketmailer.PageWorker, {:advanced, []}}
     ]},
    {~c"0.1.1",
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
       # Etag.Database: no behaviour. The code is replaced without suspending anything.
       {:load_module, Etag.Database},
       # Janice.Capture: no behaviour. The code is replaced without suspending anything.
       {:load_module, Janice.Capture},
       # Marketmailer.Log.Format: no behaviour. The code is replaced without suspending
       # anything.
       {:load_module, Marketmailer.Log.Format},
       # Mix.Tasks.Chartdb: removed by this transition. delete_module purges the module
       # and loads nothing, so never use it for a module the target build still has.
       {:delete_module, Mix.Tasks.Chartdb}
     ]}
  ]
}
