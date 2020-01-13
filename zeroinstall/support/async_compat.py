def async(fn):
	"""Decorator that turns a generator function into a function that runs the
	generator as a Task and returns the Task's finished blocker.
	@deprecated: use @tasks.aasync instead (async is a keyboard in Python 3.7)"""
	def run(*args, **kwargs):
		return Task(fn(*args, **kwargs), fn.__name__).finished
	run.__name__ = fn.__name__
	return run
