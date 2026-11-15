TARGET := iphone:clang:16.5:15.0
ARCHS = arm64

# RootHide / Dopamine (roothide) layout. Change to "rootless" if your device
# runs a plain rootless jailbreak, or remove the line for rootful.
THEOS_PACKAGE_SCHEME = roothide

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = FilesFullName
FilesFullName_FILES = Tweak.x
FilesFullName_CFLAGS = -fobjc-arc
FilesFullName_FRAMEWORKS = UIKit Foundation

include $(THEOS_MAKE_PATH)/tweak.mk
