from distutils import log
from distutils.core import setup
from distutils.core import Command
from distutils.command.build_py import build_py
from distutils.command.install import install
import os
import zeroinstall

class adjust_scripts_for_home(Command):
	"""setup.py install --home puts libraries in ~/lib/python, but Python doesn't look there.
	If we're installing with --home, modify the scripts to add this to sys.path.
	Don't do this otherwise; the system copy mustn't conflict with the copy in $HOME.
	"""
	description = "(used internally when using --home)"

	user_options = [
		    ('scripts-dir=', 'd', "directory to install scripts to"),
		    ('lib-dir=', 'd', "directory libraries install to"),
	]

	def initialize_options (self):
		self.scripts_dir = None
		self.lib_dir = None

	def finalize_options (self):
		self.set_undefined_options('install',
				('install_scripts', 'scripts_dir'),
				('install_lib', 'lib_dir'),
			)

	def run(self):
		for script in self.distribution.scripts:
			outfile = os.path.join(self.scripts_dir, os.path.basename(script))

			stream = open(outfile)
			code = stream.read()
			stream.close()

			code = code.replace('## PATH ##', '''
import os, sys
sys.path.insert(0, %s)''' % repr(self.lib_dir))
			stream = open(outfile, 'w')
			stream.write(code)
			stream.close()

class build_with_data(build_py):
	"""Python < 2.4 doesn't support package_data_files, so add it manually."""
	package_data_files = [
		"zeroinstall/gui/zero-install.ui",
		"zeroinstall/gtkui/desktop.ui",
		"zeroinstall/gtkui/cache.ui",
		"zeroinstall/injector/EquifaxSecureCA.crt",
		"zeroinstall/zerostore/_unlzma",
	]

	def run(self):
		old = log.set_threshold(log.ERROR)	# Avoid "__init__.py not found" warning
		# Copy .py files and build, as usual
		build_py.run(self)
		log.set_threshold(old)

		# Copy data files
		for data_file in self.package_data_files:
			outfile = os.path.join(self.build_lib, data_file)
			self.copy_file(data_file, outfile, preserve_mode=0)
			executable = (os.stat(data_file).st_mode & 0o111) != 0
			if executable:
				os.chmod(outfile, os.stat(outfile).st_mode | 0o111)

class my_install(install):
	def run(self):
		install.run(self)       # super.run()
		if self.home:
			self.run_command('adjust_scripts_for_home')

setup(name="zeroinstall-injector",
      version=zeroinstall.version,
      description="The Zero Install Injector (0launch)",
      author="Thomas Leonard",
      author_email="zero-install-devel@lists.sourceforge.net",
      url="http://0install.net",
      scripts=['0install-python-fallback', '0alias', '0store-secure-add', '0desktop'],
      license='LGPL',
      cmdclass={
	'build_py': build_with_data,
	'adjust_scripts_for_home': adjust_scripts_for_home,
	'install': my_install,
      },
      long_description="""\
A running process is created by combining many different libraries (and other
components). In the Zero Install world, we have all versions of each library
available at all times. The problem then is how to choose which versions to
use.

The injector solves this problem by selecting components to meet a program's
requirements, according to a policy you give it. The injector finds out which
versions are available, and downloads and runs the ones you choose.""",
      packages=["zeroinstall", "zeroinstall.support", "zeroinstall.zerostore", "zeroinstall.injector", "zeroinstall.gui", "zeroinstall.gtkui", "zeroinstall.cmd"])
