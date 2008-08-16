from distutils.core import setup
from distutils.util import convert_path
from distutils.command.build_py import build_py
from distutils.command.install import install
from distutils.command.install_lib import install_lib
from distutils.command.install_data import install_data
import os
import zeroinstall

class build_with_data(build_py):
	"""Python < 2.4 doesn't support package_data_files, so add it manually."""
	package_data_files = [
		"zeroinstall/0launch-gui/README",
		"zeroinstall/0launch-gui/0launch-gui",
		"zeroinstall/0launch-gui/ZeroInstall-GUI.xml",
		"zeroinstall/0launch-gui/zero-install.glade",
		"zeroinstall/gtkui/desktop.glade",
		"zeroinstall/gtkui/cache.glade",
	]
	def run(self):
		# Copy .py files and build, as usual
		build_py.run(self)
		# Copy data files
		for data_file in self.package_data_files:
			outfile = os.path.join(self.build_lib, data_file)
			self.copy_file(data_file, outfile, preserve_mode=0)
			executable = (os.stat(data_file).st_mode & 0111) != 0
			if executable:
				os.chmod(outfile, os.stat(outfile).st_mode | 0111)

class install_lib_exec(install_lib):
	def run(self):
		install_lib.run(self)	# super.run()
		if os.name != 'posix': return

		launch = os.path.join(self.install_dir, 'zeroinstall/0launch-gui/0launch-gui')
		os.chmod(launch, os.stat(launch).st_mode | 0111)

# distutils doesn't seem to have any support for adding configuration files.
# Unfortunately, the freedesktop.org menu spec strangely defines part of the
# menu definitions as configuration.
class my_install(install):
	def finalize_options(self):
		install.finalize_options(self)	# super.finalize_options()
		if self.home:
			self.__config_dir = os.path.join(self.home, '.config')
		elif self.prefix == '/usr':
			self.__config_dir = os.path.join(self.root or '/', 'etc/xdg')
		else:
			self.__config_dir = os.path.join(self.prefix, 'etc/xdg')

	def run(self):
		install.run(self)	# super.run()
		menus_dir = os.path.join(self.__config_dir, 'menus/applications-merged')
		self.mkpath(menus_dir)
		menu = convert_path('applications/zeroinstall.menu')
		self.copy_file(menu, menus_dir)

setup(name="zeroinstall-injector",
      version=zeroinstall.version,
      description="The Zero Install Injector (0launch)",
      author="Thomas Leonard",
      author_email="zero-install-devel@lists.sourceforge.net",
      url="http://0install.net",
      scripts=['0launch', '0alias', '0store', '0store-secure-add', '0desktop'],
      data_files = [('man/man1', ['0launch.1', '0alias.1', '0store-secure-add.1', '0store.1', '0desktop.1']),
		    ('share/applications', ['applications/zeroinstall-add.desktop', 'applications/zeroinstall-manage.desktop']),
		    ('share/desktop-directories', ['applications/zeroinstall.directory']),
		    ('share/pixmaps', ['applications/zeroinstall-zero2desktop.png'])],
      license='LGPL',
      cmdclass={
	'build_py': build_with_data,
	'install_lib': install_lib_exec,
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
      packages=["zeroinstall", "zeroinstall.support", "zeroinstall.zerostore", "zeroinstall.injector", "zeroinstall.0launch-gui", "zeroinstall.gtkui"])
