{
  ~c"0.1.3",
  [
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
