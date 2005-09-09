import os

# os_ranks and mapping are mappings from names to how good they are.
# 1 => Native (best)
# Higher numbers are worse but usable.
_uname = os.uname()

os_ranks = {
	'Linux' : 3,		# Linux (lots of systems support emulation)
	None : 2,		# Any arch
	_uname[0] : 1,		# Current OS
}

machine_ranks = {
	'i386' : 4,	# Hope for x86 emulation
	'i486' : 3,
	None : 2,	# Any OS
	_uname[-1] : 1,	# Current machine
}
