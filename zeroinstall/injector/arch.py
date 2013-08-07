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

# TODO: "import platform"?

# os_ranks and mapping are mappings from names to how good they are.
# 1 => Native (best)
# Higher numbers are worse but usable.
try:
	_uname = os.uname()
	# On Darwin, machine is wrong.
	if _uname[0] == 'Darwin' and _uname[-1] == 'i386':
		_cpu64 = os.popen('sysctl -n hw.cpu64bit_capable 2>&1').next().strip()
		if _cpu64 == '1':
			_uname = tuple(list(_uname[:-1])+['x86_64'])
except AttributeError:
	# No uname. Probably Windows.
	import sys
	p = sys.platform
	if p == 'win64':
		_uname = ('Windows', 'x86_64')
	elif p == 'win32':
		from win32process import IsWow64Process
		if IsWow64Process():
			_uname = ('Windows', 'x86_64')
		else:
			_uname = ('Windows', 'i486')
	else:
		_uname = (p, 'i486')

def canonicalize_os(os_):
	"""@type os_: str
	@rtype: str"""
	if os_.startswith('CYGWIN_NT'):
		os_ = 'Cygwin'
	elif os_ == 'SunOS':
		os_ = 'Solaris'
	return os_

def _get_os_ranks(target_os):
	"""@type target_os: str"""
	target_os = canonicalize_os(target_os)

	if target_os == 'Darwin':
		# Special case Mac OS X, to separate it from Darwin/X
		# (Mac OS X also includes the closed Apple frameworks)
		if os.path.exists('/System/Library/Frameworks/Carbon.framework'):
			target_os = 'MacOSX'

	# Binaries compiled for _this_ OS are best...
	os_ranks = {target_os : 1}

	# Assume everything supports POSIX except Windows
	# (but Cygwin is POSIX)
	if target_os != 'Windows':
		os_ranks['POSIX'] = len(os_ranks) + 1

	# If target_os appears in the first column of this table, all
	# following OS types on the line will also run on this one
	# (earlier ones preferred):
	_os_matrix = {
		'Cygwin': ['Windows'],
		'MacOSX': ['Darwin'],
	}

	for supported in _os_matrix.get(target_os, []):
		os_ranks[supported] = len(os_ranks) + 1

	# At the lowest priority, try an OS-independent implementation
	os_ranks[None] = len(os_ranks) + 1
	return os_ranks

os_ranks = _get_os_ranks(_uname[0])

# All chosen machine-specific implementations must come from the same group
# Unlisted archs are in group 0
machine_groups = {
	'x86_64': 64,
	'ppc64': 64,
}

def canonicalize_machine(machine_):
	"""@type machine_: str
	@rtype: str"""
	machine = machine_.lower()
	if machine == 'x86':
		machine = 'i386'
	elif machine == 'amd64':
		machine = 'x86_64'
	elif machine == 'Power Macintosh':
		machine = 'ppc'
	elif machine == 'i86pc':
		machine = 'i686'
	return machine

def _get_machine_ranks(target_machine, disable_multiarch = False):
	"""@type target_machine: str"""
	target_machine = canonicalize_machine(target_machine)

	# Binaries compiled for _this_machine are best...
	machine_ranks = {target_machine : 0}

	# If target_machine appears in the first column of this table, all
	# following machine types on the line will also run on this one
	# (earlier ones preferred):
	machine_matrix = {
		'i486': ['i386'],
		'i586': ['i486', 'i386'],
		'i686': ['i586', 'i486', 'i386'],
		'ppc': ['ppc32'],
	}
	if not disable_multiarch:
		machine_matrix['x86_64'] = ['i686', 'i586', 'i486', 'i386']
		machine_matrix['ppc64'] = ['ppc']

	for supported in machine_matrix.get(target_machine, []):
		machine_ranks[supported] = len(machine_ranks)

	# At the lowest priority, try a machine-independant implementation
	machine_ranks[None] = len(machine_ranks)
	return machine_ranks

machine_ranks = _get_machine_ranks(_uname[-1],
			disable_multiarch = 'Linux' in os_ranks and not os.path.exists('/lib/ld-linux.so.2'))

class Architecture(object):
	"""A description of an architecture. Use by L{solver} to make sure it chooses
	compatible versions.
	@ivar os_ranks: supported operating systems and their desirability
	@type os_ranks: {str: int}
	@ivar machine_ranks: supported CPU types and their desirability
	@type machine_ranks: {str: int}
	@ivar child_arch: architecture for dependencies (usually C{self})
	@type child_arch: L{Architecture}
	@ivar use: matching values for <requires use='...'>; otherwise the dependency is ignored
	@type use: set(str)
	"""

	use = frozenset([None])

	def __init__(self, os_ranks, machine_ranks):
		self.os_ranks = os_ranks
		self.machine_ranks = machine_ranks
		self.child_arch = self

	def __str__(self):
		"""@rtype: str"""
		return _("<Arch: %(os_ranks)s %(machine_ranks)s>") % {'os_ranks': self.os_ranks, 'machine_ranks': self.machine_ranks}

class SourceArchitecture(Architecture):
	"""Matches source code that creates binaries for a particular architecture.
	Note that the L{child_arch} here is the binary; source code depends on binary tools,
	not on other source packages.
	"""
	def __init__(self, binary_arch):
		"""@type binary_arch: L{Architecture}"""
		Architecture.__init__(self, binary_arch.os_ranks, {'src': 1})
		self.child_arch = binary_arch

def get_host_architecture():
	"""Get an Architecture that matches implementations that will run on the host machine.
	@rtype: L{Architecture}"""
	return Architecture(os_ranks, machine_ranks)

def get_architecture(os, machine):
	"""Get an Architecture that matches binaries that will work on the given system.
	@param os: OS type, or None for host's type
	@type os: str
	@param machine: CPU type, or None for host's type
	@type machine: str
	@return: an Architecture object
	@rtype: L{Architecture}"""

	if os is None:
		target_os_ranks = os_ranks
	else:
		target_os_ranks = _get_os_ranks(os)
	if machine is None:
		target_machine_ranks = machine_ranks
	else:
		target_machine_ranks = _get_machine_ranks(machine)

	return Architecture(target_os_ranks, target_machine_ranks)
