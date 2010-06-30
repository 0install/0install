"""
PackageKit integration.
"""

# Copyright (C) 2010, Aleksey Lim
# See the README file for details, or visit http://0install.net.

import os
import locale
import logging
from zeroinstall import _, SafeException

from zeroinstall.support import tasks
from zeroinstall.injector import download, model

_logger_pk = logging.getLogger('packagekit')

try:
	import dbus
	import dbus.mainloop.glib
	dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
except Exception, ex:
	_logger_pk.info("D-BUS not available: %s", ex)
	dbus = None

class PackageKit(object):
	def __init__(self):
		self._pk = False

		self._candidates = {}	# { package_name : (version, arch, size) | Blocker }

	@property
	def available(self):
		return self.pk is not None

	@property
	def pk(self):
		if self._pk is False:
			try:
				self._pk = dbus.Interface(dbus.SystemBus().get_object(
							'org.freedesktop.PackageKit',
							'/org/freedesktop/PackageKit', False),
						'org.freedesktop.PackageKit')
				_logger_pk.info(_('PackageKit dbus service found'))
			except Exception, ex:
				_logger_pk.info(_('PackageKit dbus service not found: %s'), ex)
				self._pk = None
		return self._pk

	def get_candidates(self, package_name, factory, prefix):
		"""Add any cached candidates.
		The candidates are those discovered by a previous call to L{fetch_candidates}.
		@param package_name: the distribution's name for the package
		@param factory: a function to add a new implementation to the feed
		@param prefix: the prefix for the implementation's ID
		"""
		candidate = self._candidates.get(package_name, None)
		if candidate is None:
			return

		if isinstance(candidate, tasks.Blocker):
			return		# Fetch still in progress

		impl_name = '%s:%s:%s:%s' % (prefix, package_name, candidate['version'], candidate['arch'])

		impl = factory(impl_name, only_if_missing = True, installed = candidate['installed'])
		if impl is None:
			# (checking this way because the cached candidate['installed'] may be stale)
			return		# Already installed

		impl.version = model.parse_version(candidate['version'])
		if candidate['arch'] != '*':
			impl.machine = candidate['arch']

		def install(handler):
			packagekit_id = candidate['packagekit_id']
			def download_factory(url, hint):
				return PackageKitDownload(url, hint, pk = self.pk, packagekit_id = packagekit_id)
			dl = handler.get_download('packagekit:' + packagekit_id, factory = download_factory, hint = impl)
			dl.expected_size = candidate['size']
			return dl.downloaded
		impl.download_sources.append(model.DistributionSource(package_name, candidate['size'], install))

	@tasks.async
	def fetch_candidates(self, package_names):
		assert self.pk

		known = [self._candidates[p] for p in package_names if p in self._candidates]
		in_progress = [b for b in known if isinstance(b, tasks.Blocker)]
		_logger_pk.debug('Already downloading: %s', in_progress)

		# Filter out the ones we've already fetched
		package_names = [p for p in package_names if p not in self._candidates]

		if package_names:
			versions = {}

			blocker = None

			def error_cb(sender):
				# Note: probably just means the package wasn't found
				_logger_pk.info(_('Transaction failed: %s(%s)'), sender.error_code, sender.error_details)
				blocker.trigger()

			def details_cb(sender):
				if sender.details:
					for packagekit_id, info in versions.items():
						info.update(sender.details[packagekit_id])
						info['packagekit_id'] = packagekit_id
						self._candidates[info['name']] = info
				else:
					_logger_pk.warn(_('Empty details for %s'), package_names)
				blocker.trigger()

			def resolve_cb(sender):
				if sender.package:
					versions.update(sender.package)
					tran = _PackageKitTransaction(self.pk, details_cb, error_cb)
					tran.proxy.GetDetails(versions.keys())
				else:
					_logger_pk.info(_('Empty resolve for %s'), package_names)
					blocker.trigger()

			# Send queries
			blocker = tasks.Blocker('PackageKit %s' % package_names)
			for package in package_names:
				self._candidates[package] = blocker

			_logger_pk.debug(_('Ask for %s'), package_names)
			tran = _PackageKitTransaction(self.pk, resolve_cb, error_cb)
			tran.proxy.Resolve('none', package_names)

			in_progress.append(blocker)

		while in_progress:
			yield in_progress
			in_progress = [b for b in in_progress if not b.happened]

class PackageKitDownload(download.Download):
	def __init__(self, url, hint, pk, packagekit_id):
		download.Download.__init__(self, url, hint)

		self.packagekit_id = packagekit_id
		self._impl = hint
		self._transaction = None
		self.pk = pk

	def start(self):
		assert self.status == download.download_starting
		assert self.downloaded is None

		def error_cb(sender):
			self.status = download.download_failed
			ex = SafeException('PackageKit install failed: %s' % (sender.error_details or sender.error_code))
			self.downloaded.trigger(exception = (ex, None))

		def installed_cb(sender):
			self._impl.installed = True;
			self.status = download.download_complete
			self.downloaded.trigger()

		def install_packages():
			package_name = self.packagekit_id
			self._transaction = _PackageKitTransaction(self.pk, installed_cb, error_cb)
			self._transaction.compat_call([
					('InstallPackages', [package_name]),
					('InstallPackages', False, [package_name]),
					])

		_auth_wrapper(install_packages)

		self.status = download.download_fetching
		self.downloaded = tasks.Blocker('PackageKit install %s' % self.packagekit_id)

	def abort(self):
		_logger_pk.debug(_('Cancel transaction'))
		self.aborted_by_user = True
		self._transaction.proxy.Cancel()
		self.status = download.download_failed
		self.downloaded.trigger()

	def get_current_fraction(self):
		if self._transaction is None:
			return None
		percentage = self._transaction.getPercentage()
		if percentage > 100:
			return None
		else:
			return float(percentage) / 100.

	def get_bytes_downloaded_so_far(self):
		fraction = self.get_current_fraction()
		if fraction is None:
			return 0
		else:
			return int(self.expected_size * fraction)

def _auth_wrapper(method, *args):
	try:
		return method(*args)
	except dbus.exceptions.DBusException, e:
		if e.get_dbus_name() != \
				'org.freedesktop.PackageKit.Transaction.RefusedByPolicy':
			raise

		iface, auth = e.get_dbus_message().split()
		if not auth.startswith('auth_'):
			raise

		_logger_pk.debug(_('Authentication required for %s'), auth)

		pk_auth = dbus.SessionBus().get_object(
				'org.freedesktop.PolicyKit.AuthenticationAgent', '/',
				'org.gnome.PolicyKit.AuthorizationManager.SingleInstance')

		if not pk_auth.ObtainAuthorization(iface, dbus.UInt32(0),
				dbus.UInt32(os.getpid()), timeout=300):
			raise

		return method(*args)

class _PackageKitTransaction(object):
	def __init__(self, pk, finished_cb=None, error_cb=None):
		self._finished_cb = finished_cb
		self._error_cb = error_cb
		self.error_code = None
		self.error_details = None
		self.package = {}
		self.details = {}
		self.files = {}

		self.object = dbus.SystemBus().get_object(
				'org.freedesktop.PackageKit', pk.GetTid(), False)
		self.proxy = dbus.Interface(self.object,
				'org.freedesktop.PackageKit.Transaction')
		self._props = dbus.Interface(self.object, dbus.PROPERTIES_IFACE)

		for signal, cb in [('Finished', self.__finished_cb),
				   ('ErrorCode', self.__error_code_cb),
				   ('StatusChanged', self.__status_changed_cb),
				   ('Package', self.__package_cb),
				   ('Details', self.__details_cb),
				   ('Files', self.__files_cb)]:
			self.proxy.connect_to_signal(signal, cb)

		self.compat_call([
				('SetLocale', locale.getdefaultlocale()[0]),
				('SetHints', ['locale=%s' % locale.getdefaultlocale()[0]]),
				])

	def getPercentage(self):
		result = self.get_prop('Percentage')
		if result is None:
			result, __, __, __ = self.proxy.GetProgress()
		return result

	def get_prop(self, prop, default = None):
		try:
			return self._props.Get('org.freedesktop.PackageKit.Transaction', prop)
		except:
			return default

	def compat_call(self, calls):
		for call in calls:
			method = call[0]
			args = call[1:]
			try:
				dbus_method = self.proxy.get_dbus_method(method)
				return dbus_method(*args)
			except dbus.exceptions.DBusException, e:
				if e.get_dbus_name() != \
						'org.freedesktop.DBus.Error.UnknownMethod':
					raise
		raise Exception('Cannot call %r DBus method' % calls)

	def __finished_cb(self, exit, runtime):
		_logger_pk.debug(_('Transaction finished: %s'), exit)
		if self.error_code is not None:
			self._error_cb(self)
		else:
			self._finished_cb(self)

	def __error_code_cb(self, code, details):
		_logger_pk.info(_('Transaction failed: %s(%s)'), details, code)
		self.error_code = code
		self.error_details = details

	def __package_cb(self, status, id, summary):
		from zeroinstall.injector import distro

		package_name, version, arch, repo_ = id.split(';')
		clean_version = distro.try_cleanup_distro_version(version)
		if not clean_version:
			_logger_pk.warn(_("Can't parse distribution version '%(version)s' for package '%(package)s'"), {'version': version, 'package': package_name})
		clean_arch = distro.canonical_machine(arch)
		package = {'version': clean_version,
			   'name': package_name,
			   'arch': clean_arch,
			   'installed': (status == 'installed')}
		_logger_pk.debug(_('Package: %s %r'), id, package)
		self.package[str(id)] = package

	def __details_cb(self, id, licence, group, detail, url, size):
		details = {'licence': str(licence),
				   'group': str(group),
				   'detail': str(detail),
				   'url': str(url),
				   'size': long(size)}
		_logger_pk.debug(_('Details: %s %r'), id, details)
		self.details[id] = details

	def __files_cb(self, id, files):
		self.files[id] = files.split(';')

	def __status_changed_cb(self, status):
		pass
