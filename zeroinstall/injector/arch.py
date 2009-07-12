"""
Information about the current system's architecture.

This module provides information about the current system. It is used to determine
whether an implementation is suitable for this machine, and to compare different implementations.

For example, it will indicate that:

 - An i486 machine cannot run an i686 binary.
 - An i686 machine can run an i486 binary, but would prefer an i586 one.
 - A Windows binary cannot run on a Linux machine.

Each dictionary maps from a supported architecture type to a preference level. Lower numbers are
better, Unsupported architectures are not listed at all.
"""

# Copyright (C) 2009, Thomas Leonard
# See the README file for details, or visit http://0install.net.

from zeroinstall import _
import os

# os_ranks and mapping are mappings from names to how good they are.
# 1 => Native (best)
# Higher numbers are worse but usable.
try:
	_uname = os.uname()
except AttributeError:
	# No uname. Probably Windows (untested).
	import sys
	p = sys.platform
	if p == 'win32':
		_uname = ('Windows', 'i486')
	elif p == 'win64':
		_uname = ('Windows', 'x86_64')
	else:
		_uname = (p, 'i486')

os_ranks = {
#	'Linux' : 3,		# Linux (lots of systems support emulation)
	None : 2,		# Any OS
	_uname[0] : 1,		# Current OS
}

# All chosen machine-specific implementations must come from the same group
# Unlisted archs are in group 0
machine_groups = {
	'x86_64': 64,
	'ppc64': 64,
}

def _get_machine_ranks(target_machine):
	# Binaries compiled for _this_machine are best...
	machine_ranks = {target_machine : 0}

	# If target_machine appears in the first column of this table, all
	# following machine types on the line will also run on this one
	# (earlier ones preferred):
	_machine_matrix = {
		'i486': ['i386'],
		'i586': ['i486', 'i386'],
		'i686': ['i586', 'i486', 'i386'],
		'x86_64': ['i686', 'i586', 'i486', 'i386'],
		'ppc64': ['ppc32'],
	}
	for supported in _machine_matrix.get(target_machine, []):
		machine_ranks[supported] = len(machine_ranks)

	# At the lowest priority, try a machine-independant implementation
	machine_ranks[None] = len(machine_ranks)
	return machine_ranks

machine_ranks = _get_machine_ranks(_uname[-1])
#print machine_ranks
	
class Architecture:
	"""A description of an architecture. Use by L{solver} to make sure it chooses
	compatible versions.
	@ivar os_ranks: supported operating systems and their desirability
	@type os_ranks: {str: int}
	@ivar machine_ranks: supported CPU types and their desirability
	@type machine_ranks: {str: int}
	@ivar child_arch: architecture for dependencies (usually C{self})
	@type child_arch: L{Architecture}"""
	def __init__(self, os_ranks, machine_ranks):
		self.os_ranks = os_ranks
		self.machine_ranks = machine_ranks
		self.child_arch = self
	
	def __str__(self):
		return _("<Arch: %(os_ranks)s %(machine_ranks)s>") % {'os_ranks': self.os_ranks, 'machine_ranks': self.machine_ranks}

class SourceArchitecture(Architecture):
	"""Matches source code that creates binaries for a particular architecture.
	Note that the L{child_arch} here is the binary; source code depends on binary tools,
	not on other source packages.
	"""
	def __init__(self, binary_arch):
		Architecture.__init__(self, binary_arch.os_ranks, {'src': 1})
		self.child_arch = binary_arch
	
def get_host_architecture():
	"""Get an Architecture that matches implementations that will run on the host machine.
	@rtype: L{Architecture}"""
	return Architecture(os_ranks, machine_ranks)

def get_architecture(os, machine):
	"""Get an Architecture that matches binaries that will work on the given system.
	@param os: OS type, or None for host's type
	@param machine: CPU type, or None for host's type
	@return: an Architecture object
	@rtype: L{Architecture}"""

	if os:
		target_os_ranks = {
			os : 1,		# Perfer binaries for target OS
			None : 2,	# Otherwise, generic OS is fine
		}
	else:
		target_os_ranks = os_ranks
	if machine:
		target_machine_ranks = _get_machine_ranks(machine)
	else:
		target_machine_ranks = machine_ranks
	return Architecture(target_os_ranks, target_machine_ranks)
