# Copyright (C) 2010, Thomas Leonard
# See the README file for details, or visit http://0install.net.

import tempfile, subprocess, os, sys
from logging import warn

class Problem:
	def __init__(self):
		self.var_names = set()
		self.next_group = 0
		self.group_of = {}		# var -> group
		self.assigned = {}		# var -> [0|1]
		self.clauses = []

	def add_variable(self, var_name):
		assert var_name not in self.var_names
		self.var_names.add(var_name)
	
	def at_most_one(self, var_names):
		for var in var_names:
			assert var not in self.group_of
			self.group_of[var] = self.next_group
		self.next_group += 1
	
	def exactly_one(self, var_names):
		self.at_most_one(var_names)
		self.add_clause(var_names)	# at least one
	
	def impossible(self):
		self.var_names.add("impossible")
		self.clauses.append(["impossible"])
		self.clauses.append([self.neg("impossible")])

	def assign(self, var, value):
		assert value in [0, 1]
		assert var not in self.assigned
		self.assigned[var] = value
	
	def add_clause(self, clause):
		assert clause
		self.clauses.append(clause)
	
	def neg(self, var):
		assert var in self.var_names
		return "-" + var

	def run_solver(self, minimise):
		comment_problem = False
		selected = []
		ready = False
		prog_fd, tmp_name = tempfile.mkstemp(prefix = '0launch-')
		try:
			stream = os.fdopen(prog_fd, 'wb')
			try:
				print >>stream, "min:", ' + '.join("%d * %s" % (cost, name) for name, cost in minimise.iteritems()) + ";"
				for clause in self.clauses:
					positive = ['1 * ' + var for var in clause if not var.startswith('-')]
					negative = ['-1 * ' + var[1:] for var in clause if var.startswith('-')]
					needed = 1 - len(negative)
					print >>stream, ' + '.join(positive + negative).replace('+ -', '- ') + ' >= %d;' % needed
				groups = {}
				for var, group in self.group_of.iteritems():
					if group not in groups:
						groups[group] = []
					groups[group].append(var)
				for group, var_names in groups.iteritems():
					print >>stream, ' + '.join('1 * ' + var for var in var_names) + ' <= 1;'
				for var, value in self.assigned.iteritems():
					print >>stream, '1 * ' + var + ' = %d;' % value
			finally:
				stream.close()
			if False:
				 print >>sys.stderr, open(tmp_name).read()
			child = subprocess.Popen(['minisat+', tmp_name, '-v0'], stdout = subprocess.PIPE)
			data, used = child.communicate()
			for line in data.split('\n'):
				if line.startswith('v '):
					bits = line.split(' ')[1:]
					for bit in bits:
						if comment_problem and not bit.startswith("-"):
							print >>sys.stderr, bit
						if bit.startswith('f'):
							selected.append(bit)

				elif line == "s OPTIMUM FOUND":
					if comment_problem:
						print >>sys.stderr, line
					ready = True
				elif line == "s UNSATISFIABLE":
					return False, False
				elif line:
					warn("Unexpected output from solver: %s", line)
		finally:
			os.unlink(tmp_name)

		return ready, selected

