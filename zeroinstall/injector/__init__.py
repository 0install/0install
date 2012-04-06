"""
Code relating to interfaces and policies.

To run a program, the following steps are typical:

 1. Create some L{requirements.Requirements}, giving the root interface's URI.
 2. Instantiate a L{driver.Driver}, giving it the requirements
 3. Ask the driver to choose a set of implementations.
   1. The driver will try to find a compatible set of implementations that meet the user's policy
      and work on the current L{arch}itecture, using a L{solve.Solver}.
   2. The solver looks up feeds in the L{iface_cache}.
   3. The driver will L{fetch} any feeds that are missing.
   4. The cached or downloaded XML is parsed into a L{model} using the L{reader} module.
 4. Download the selected implementations and L{zerostore.unpack} into the L{zerostore}.
 5. Finally, L{run} the program.

The L{cli} module provides the B{0launch} command-line interface.
"""
