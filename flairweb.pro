QT += core core-private gui qml quick quickcontrols2 network webenginequick webenginecore

CONFIG += c++17 release
TARGET = flairweb
TEMPLATE = app

HEADERS += \
    src/ai.h \
    src/browser.h \
    src/dnr.h \
    src/extensionhost.h \
    src/engines.h \
    src/favicons.h \
    src/launcher.h \
    src/library.h \
    src/pageai.h \
    src/settings.h \
    src/shield.h \
    src/theme.h

SOURCES += \
    src/main.cpp \
    src/ai.cpp \
    src/browser.cpp \
    src/dnr.cpp \
    src/extensionhost.cpp \
    src/engines.cpp \
    src/favicons.cpp \
    src/launcher.cpp \
    src/library.cpp \
    src/pageai.cpp \
    src/settings.cpp \
    src/shield.cpp \
    src/theme.cpp

RESOURCES += src/resources.qrc
