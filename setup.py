from distutils.core import setup
setup(name="injector",
      version="0.3",
      description="The Zero Install Injector (0launch)",
      author="Thomas Leonard",
      author_email="-",
      url="http://0install.net",
      scripts=['0launch', '0launch-gui'],
      license='GPL',
      packages=["zeroinstall", "zeroinstall.zerostore", "zeroinstall.injector"])
