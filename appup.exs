{
  ~c"0.1.19",
  [
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
