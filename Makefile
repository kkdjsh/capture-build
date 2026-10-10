THEOS = /Users/runner/theos
TARGET := iphone:clang:latest:14.0
ARCHS = arm64
include $(THEOS)/makefiles/common.mk
TWEAK_NAME = Capture
Capture_FILES = Tweak.xm
Capture_CFLAGS = -fobjc-arc -Wno-error
Capture_PRIVATE_FRAMEWORKS = UIKit Foundation Security
include $(THEOS_MAKE_PATH)/tweak.mk
