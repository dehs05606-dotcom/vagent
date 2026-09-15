import Lake
open Lake DSL

package «lean-prime» where
  leanOptions := #[
    ⟨`autoImplicit, false⟩,
    ⟨`relaxedAutoImplicit, false⟩
  ]

@[default_target]
lean_lib LeanPrime where
  globs := #[.submodules `LeanPrime]

@[default_target]
lean_exe «lean-prime» where
  root := `Main
  supportInterpreter := true

lean_exe «lean-prime-tests» where
  root := `Tests.Main
  supportInterpreter := true
