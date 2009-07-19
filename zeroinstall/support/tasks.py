"""The tasks module provides a simple light-weight alternative to threads.

When you have a long-running job you will want to run it in the background,
while the user does other things. There are four ways to do this:

 - Use a new thread for each task.
 - Use callbacks from an idle handler.
 - Use a recursive mainloop.
 - Use this module.

Using threads causes a number of problems. Some builds of pygtk/python don't
support them, they introduce race conditions, often lead to many subtle
bugs, and they require lots of resources (you probably wouldn't want 10,000
threads running at once). In particular, two threads can run at exactly the
same time (perhaps on different processors), so you have to be really careful
that they don't both try to update the same variable at the same time. This
requires lots of messy locking, which is hard to get right.

Callbacks work within a single thread. For example, you open a dialog box and
then tell the system to call one function if it's closed, and another if the
user clicks OK, etc. The function that opened the box then returns, and the
system calls one of the given callback functions later. Callbacks only
execute one at a time, so you don't have to worry about race conditions.
However, they are often very awkward to program with, because you have to
save state somewhere and then pass it to the functions when they're called.

A recursive mainloop only works with nested tasks (you can create a
sub-task, but the main task can't continue until the sub-task has
finished). We use these for, eg, rox.alert() boxes since you don't
normally want to do anything else until the box is closed, but it is not
appropriate for long-running jobs.

Tasks use python's generator API to provide a more pleasant interface to
callbacks. See the Task class (below) for more information.
"""

# Copyright (C) 2009, Thomas Leonard
# See the README file for details, or visit http://0install.net.

from zeroinstall import _
import sys
from logging import info, warn
import gobject

# The list of Blockers whose event has happened, in the order they were
# triggered
_run_queue = []

def check(blockers, reporter = None):
	"""See if any of the blockers have pending exceptions.
	@param reporter: invoke this function on each error
	If reporter is None, raise the first and log the rest."""
	ex = None
	if isinstance(blockers, Blocker):
		blockers = (blockers,)
	for b in blockers:
		if b.exception:
			b.exception_read = True
			if reporter:
				reporter(*b.exception)
			elif ex is None:
				ex = b.exception
			else:
				warn(_("Multiple exceptions waiting; skipping %s"), b.exception[0])
	if ex:
		raise ex[0], None, ex[1]

class Blocker:
	"""A Blocker object starts life with 'happened = False'. Tasks can
	ask to be suspended until 'happened = True'. The value is changed
	by a call to trigger().

	Example:

	>>> kettle_boiled = tasks.Blocker()
	>>> def make_tea():
		print "Get cup"
		print "Add tea leaves"
		yield kettle_boiled
		print "Pour water into cup"
		print "Brew..."
		yield tasks.TimeoutBlocker(120)
		print "Add milk"
		print "Ready!"
	>>> tasks.Task(make_tea())

	Then elsewhere, later::

		print "Kettle boiled!"
		kettle_boiled.trigger()
	
	You can also yield a list of Blockers. Your function will resume
	after any one of them is triggered. Use blocker.happened to
	find out which one(s). Yielding a Blocker that has already
	happened is the same as yielding None (gives any other Tasks a
	chance to run, and then continues).
	"""

	exception = None

	def __init__(self, name):
		self.happened = False		# False until event triggered
		self._zero_lib_tasks = set()	# Tasks waiting on this blocker
		self.name = name

	def trigger(self, exception = None):
		"""The event has happened. Note that this cannot be undone;
		instead, create a new Blocker to handle the next occurance
		of the event.
		@param exception: exception to raise in waiting tasks
		@type exception: (Exception, traceback)"""
		if self.happened: return	# Already triggered
		self.happened = True
		self.exception = exception
		self.exception_read = False
		#assert self not in _run_queue	# Slow
		if not _run_queue:
			_schedule()
		_run_queue.append(self)

		if exception:
			assert isinstance(exception, tuple), exception
			if not self._zero_lib_tasks:
				info(_("Exception from '%s', but nothing is waiting for it"), self)
			#import traceback
			#traceback.print_exception(exception[0], None, exception[1])

	def __del__(self):
		if self.exception and not self.exception_read:
			warn(_("Blocker %(blocker)s garbage collected without having it's exception read: %(exception)s"), {'blocker': self, 'exception': self.exception})
	
	def add_task(self, task):
		"""Called by the schedular when a Task yields this
		Blocker. If you override this method, be sure to still
		call this method with Blocker.add_task(self)!"""
		self._zero_lib_tasks.add(task)
	
	def remove_task(self, task):
		"""Called by the schedular when a Task that was waiting for
		this blocker is resumed."""
		self._zero_lib_tasks.remove(task)
	
	def __repr__(self):
		return "<Blocker:%s>" % self

	def __str__(self):
		return self.name

class IdleBlocker(Blocker):
	"""An IdleBlocker blocks until a task starts waiting on it, then
	immediately triggers. An instance of this class is used internally
	when a Task yields None."""
	def add_task(self, task):
		"""Also calls trigger."""
		Blocker.add_task(self, task)
		self.trigger()

class TimeoutBlocker(Blocker):
	"""Triggers after a set number of seconds."""
	def __init__(self, timeout, name):
		"""Trigger after 'timeout' seconds (may be a fraction)."""
		Blocker.__init__(self, name)
		gobject.timeout_add(long(timeout * 1000), self._timeout)
	
	def _timeout(self):
		self.trigger()

def _io_callback(src, cond, blocker):
	blocker.trigger()
	return False

class InputBlocker(Blocker):
	"""Triggers when os.read(stream) would not block."""
	_tag = None
	_stream = None
	def __init__(self, stream, name):
		Blocker.__init__(self, name)
		self._stream = stream
	
	def add_task(self, task):
		Blocker.add_task(self, task)
		if self._tag is None:
			self._tag = gobject.io_add_watch(self._stream, gobject.IO_IN | gobject.IO_HUP,
				_io_callback, self)
	
	def remove_task(self, task):
		Blocker.remove_task(self, task)
		if not self._zero_lib_tasks:
			gobject.source_remove(self._tag)
			self._tag = None

class OutputBlocker(Blocker):
	"""Triggers when os.write(stream) would not block."""
	_tag = None
	_stream = None
	def __init__(self, stream, name):
		Blocker.__init__(self, name)
		self._stream = stream
	
	def add_task(self, task):
		Blocker.add_task(self, task)
		if self._tag is None:
			self._tag = gobject.io_add_watch(self._stream, gobject.IO_OUT | gobject.IO_HUP,
				_io_callback, self)
	
	def remove_task(self, task):
		Blocker.remove_task(self, task)
		if not self._zero_lib_tasks:
			gobject.source_remove(self._tag)
			self._tag = None

_idle_blocker = IdleBlocker("(idle)")

class Task:
	"""Create a new Task when you have some long running function to
	run in the background, but which needs to do work in 'chunks'.
	Example:

	>>> from zeroinstall import tasks
	>>> def my_task(start):
		for x in range(start, start + 5):
			print "x =", x
			yield None

	>>> tasks.Task(my_task(0))
	>>> tasks.Task(my_task(10))
	>>> mainloop()

	Yielding None gives up control of the processor to another Task,
	causing the sequence printed to be interleaved. You can also yield a
	Blocker (or a list of Blockers) if you want to wait for some
	particular event before resuming (see the Blocker class for details).
	"""

	def __init__(self, iterator, name):
		"""Call iterator.next() from a glib idle function. This function
		can yield Blocker() objects to suspend processing while waiting
		for events. name is used only for debugging."""
		assert iterator.next, "Object passed is not an iterator!"
		self.iterator = iterator
		self.finished = Blocker(name)
		# Block new task on the idle handler...
		_idle_blocker.add_task(self)
		self._zero_blockers = (_idle_blocker,)
		info(_("Scheduling new task: %s"), self)
	
	def _resume(self):
		# Remove from our blockers' queues
		exception = None
		for blocker in self._zero_blockers:
			blocker.remove_task(self)
		# Resume the task
		try:
			new_blockers = self.iterator.next()
		except StopIteration:
			# Task ended
			self.finished.trigger()
			return
		except SystemExit:
			raise
		except (Exception, KeyboardInterrupt), ex:
			# Task crashed
			info(_("Exception from '%(name)s': %(exception)s"), {'name': self.finished.name, 'exception': ex})
			#import traceback
			#traceback.print_exc()
			tb = sys.exc_info()[2]
			self.finished.trigger(exception = (ex, tb))
			return
		if new_blockers is None:
			# Just give up control briefly
			new_blockers = (_idle_blocker,)
		else:
			if isinstance(new_blockers, Blocker):
				# Wrap a single yielded blocker into a list
				new_blockers = (new_blockers,)
			# Are we blocking on something that already happened?
			for blocker in new_blockers:
				assert hasattr(blocker, 'happened'), "Not a Blocker: %s from %s" % (blocker, self)
				if blocker.happened:
					new_blockers = (_idle_blocker,)
					info(_("Task '%(task)s' waiting on ready blocker %(blocker)s!"), {'task': self, 'blocker': blocker})
					break
			else:
				info(_("Task '%(task)s' stopping and waiting for '%(new_blockers)s'"), {'task': self, 'new_blockers': new_blockers})
		# Add to new blockers' queues
		for blocker in new_blockers:
			blocker.add_task(self)
		self._zero_blockers = new_blockers
	
	def __repr__(self):
		return "Task(%s)" % self.finished.name
	
	def __str__(self):
		return self.finished.name

# Must append to _run_queue right after calling this!
def _schedule():
	assert not _run_queue
	gobject.idle_add(_handle_run_queue)

def _handle_run_queue():
	global _idle_blocker
	assert _run_queue

	next = _run_queue[0]
	assert next.happened

	if next is _idle_blocker:
		# Since this blocker will never run again, create a
		# new one for future idling.
		_idle_blocker = IdleBlocker("(idle)")
	elif next._zero_lib_tasks:
		info(_("Running %(task)s due to triggering of '%(next)s'"), {'task': next._zero_lib_tasks, 'next': next})
	else:
		info(_("Running %s"), next)
	
	tasks = frozenset(next._zero_lib_tasks)
	if tasks:
		next.noticed = True
	
	for task in tasks:
		# Run 'task'.
		task._resume()
	
	del _run_queue[0]

	if _run_queue:
		return True
	return False

def named_async(name):
	"""Decorator that turns a generator function into a function that runs the
	generator as a Task and returns the Task's finished blocker.
	@param name: the name for the Task"""
	def deco(fn):
		def run(*args, **kwargs):
			return Task(fn(*args, **kwargs), name).finished
		run.__name__ = fn.__name__
		return run
	return deco

def async(fn):
	"""Decorator that turns a generator function into a function that runs the
	generator as a Task and returns the Task's finished blocker."""
	def run(*args, **kwargs):
		return Task(fn(*args, **kwargs), fn.__name__).finished
	run.__name__ = fn.__name__
	return run
