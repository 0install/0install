from distutils.core import setup
import zeroinstall

setup(name="injector",
      version=zeroinstall.version,
      description="The Zero Install Injector (0launch)",
      author="Thomas Leonard",
      author_email="-",
      url="http://0install.net",
      scripts=['0launch', '0launch-gui'],
      license='GPL',
      packages=["zeroinstall", "zeroinstall.zerostore", "zeroinstall.injector"])
