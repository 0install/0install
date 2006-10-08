"""
Code relating to interfaces and policies.

To run a program using the injector, the following steps are typical:

 1. Instantiate a L{policy.Policy} (or a sub-class of it), giving it the root interface's URI.
 2. Ask the policy object to choose a set of implementations.
   1. The policy fetches interfaces from the L{iface_cache}, starting a L{download} if needed.
   2. The cached or downloaded XML is parsed into a L{model} using the L{reader} module.
   3. The policy selects a set of implementations suitable for the current L{arch}.
 3. Download the selected implementations and unpack into the L{zerostore}.
 4. Finally, L{run} the program.

For simple command-line use, the L{autopolicy} module provides code to perform the above steps. This
is used by the L{cli} module to provide the B{0launch} interface.
"""
