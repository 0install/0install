"""
Code relating to interfaces and policies.

To run a program using the injector, the following steps are typical:

 1. Instantiate a L{policy.Policy}, giving it the root interface's URI.
 2. Ask the policy object to choose a set of implementations.
   1. The policy will try to find a compatible set of implementations that meet the user's policy
      and work on the current L{arch}itecture, using a L{solve.Solver}.
   2. The solver looks up feeds in the L{iface_cache}.
   3. The policy will L{fetch} any feeds that are missing or out of date.
   4. The cached or downloaded XML is parsed into a L{model} using the L{reader} module.
 3. Download the selected implementations and L{zerostore.unpack} into the L{zerostore}.
 4. Finally, L{run} the program.

The L{cli} module provides the B{0launch} command-line interface.
"""
