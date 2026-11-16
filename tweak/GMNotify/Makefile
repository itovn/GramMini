# GMNotify — tweak nhỏ nạp vào SpringBoard (MobileSubstrate), đi kèm gói GramMini (D18). iOS 5 / 6 chỉ tạo mục «Thông báo»
# (BulletinBoard) cho app bên thứ ba (cài ở /var/mobile/Applications); GramMini là gói Cydia ở /Applications nên bị coi là app
# hệ thống → thông báo của nó bị bỏ dù người dùng đã cho phép. Tweak thêm vn.grammini.app vào các danh sách app có thông báo.
# Dựng cùng app (app/Makefile: SUBPROJECTS) → gói GramMini cài GMNotify.dylib + GMNotify.plist vào
# /Library/MobileSubstrate/DynamicLibraries; lần đầu cần khởi động lại SpringBoard.
TARGET := iphone:clang:9.3:5.0
ARCHS = armv7
include $(THEOS)/makefiles/common.mk
TWEAK_NAME = GMNotify
GMNotify_FILES = main.m
GMNotify_FRAMEWORKS = Foundation
GMNotify_CFLAGS = -fobjc-arc
GMNotify_CODESIGN_FLAGS = -S -Hsha1
include $(THEOS_MAKE_PATH)/tweak.mk
