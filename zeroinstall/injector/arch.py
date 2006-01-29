# Copyright (C) 2006, Thomas Leonard
# See the README file for details, or visit http://0install.net.

import os

# os_ranks and mapping are mappings from names to how good they are.
# 1 => Native (best)
# Higher numbers are worse but usable.
_uname = os.uname()

os_ranks = {
#	'Linux' : 3,		# Linux (lots of systems support emulation)
	None : 2,		# Any OS
	_uname[0] : 1,		# Current OS
}

def _get_machine_ranks():
	# Binaries compiled for _this_machine are best...
	this_machine = _uname[-1]
	machine_ranks = {this_machine : 0}

	# If this_machine appears in the first column of this table, all
	# following machine types on the line will also run on this one
	# (earlier ones preferred):
	_machine_matrix = {
		'i486': ['i386'],
		'i586': ['i486', 'i386'],
		'i686': ['i586', 'i486', 'i386'],
		'ppc64': ['ppc32'],
	}
	for supported in _machine_matrix.get(this_machine, []):
		machine_ranks[supported] = len(machine_ranks)

	# At the lowest priority, try a machine-independant implementation
	machine_ranks[None] = len(machine_ranks)
	return machine_ranks

machine_ranks = _get_machine_ranks()
#print machine_ranks
