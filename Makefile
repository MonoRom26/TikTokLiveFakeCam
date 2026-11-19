TARGET := iphone:clang:latest:14.0
ARCHS := arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = TikTokLiveFakeCam

$(TWEAK_NAME)_FILES = Tweak.x
$(TWEAK_NAME)_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
$(TWEAK_NAME)_FRAMEWORKS = UIKit Foundation AVFoundation CoreMedia CoreVideo Photos PhotosUI

include $(THEOS_MAKE_PATH)/tweak.mk
