# Appup source for the :appup compiler (see mix.exs `appup:` key).
#
# Versioning standard (SemVer, single source of truth = mix.exs version):
# - PATCH (0.1.x): logic-only change, hot-upgradeable via Castle.
#   Every shipped hot upgrade MUST bump mix.exs + add an entry here.
# - MINOR (0.x.0): feature, migration, or `restart_emulator` step.
# - MAJOR (x.0.0): breaking state/ETS/DB shape (needs restart, not hot-load).
#
# Not every code change needs a version: edit/test/restart freely. A version
# is only required when you want that change delivered as a Castle hot
# upgrade (unpack/install/commit) instead of a restart.
#
# To draft the next entry after changing modules:
#   mix castle.appup.gen
# then review, then build with `upgrade_from: ["tar:artifacts/..."]` so
# Forecastle generates the relup during `mix release`.
{
  ~c"0.1.1",
  [
    {~c"0.1.0",
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
       {:load_module, Marketmailer.Log.Format},
       # Mix.Tasks.Test.Safe: behaviour Mix.Task. release_handler migrates no state for
       # it, so the code is replaced without suspending anything. If the module holds
       # state that changes shape, load_module is not enough.
       {:load_module, Mix.Tasks.Test.Safe}
     ]}
  ],
  [
    {~c"0.1.0",
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
       {:load_module, Marketmailer.Log.Format},
       # Mix.Tasks.Test.Safe: behaviour Mix.Task. release_handler migrates no state for
       # it, so the code is replaced without suspending anything. If the module holds
       # state that changes shape, load_module is not enough.
       {:load_module, Mix.Tasks.Test.Safe}
     ]}
  ]
}
