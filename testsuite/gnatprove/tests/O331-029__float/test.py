from test_support import *

prove_all(prover=["z3"],
          steps=1,
          opt=["-u","sensfusion6_pack.adb","--no-axiom-guard"],
          counterexample=False)
