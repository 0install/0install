user_callback = None		# Invoked in a callback when a question box is displayed
class mainloop:
	class glib:
		@classmethod
		def DBusGMainLoop(a, set_as_default = False):
			pass

system_services = {}	# {service_name: {path: object}}

class SessionBus:
	def get_object(self, service, path):
		return None

class SystemBus:
	def get_object(self, service, path):
		service = system_services.get(service, None)
		if service:
			return service[path]
		return None

def Interface(obj, iface):
	return obj

class NotifyCb:
	def __init__(self):
		self.callback = {}
		self.boxes = []
	
	def GetCapabilities(self):
		pass
	
	def Notify(self, *args):
		self.boxes.append(args)
		nid = len(self.boxes)

		app, replaces_id, icon, title, message, actions, hints, timeout = args

		if actions:
			user_callback(self.callback['ActionInvoked'], nid, actions)

		return nid

	def connect_to_signal(self, signal, callback):
		self.callback[signal] = callback

class Byte:
	def __init__(self, value):
		pass
