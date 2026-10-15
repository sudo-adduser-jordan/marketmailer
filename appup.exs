{
  ~c"0.1.18",
  [
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
