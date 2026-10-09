# HIDAPI 0.15.0

Unmodified macOS source and headers from https://github.com/libusb/hidapi, tag `hidapi-0.15.0`, commit `d6b2a974608dec3b76fb1e36c189f22b9cf3650c`.

Used under the BSD license in LICENSE-bsd.txt. All upstream license alternatives are preserved. Linphone macOS 5.5.23 links against `@rpath/libhidapi.0.dylib` but does not ship it in its Swift package. The Mac target builds this library from source, embeds and signs it, and includes its BSD notice. No Homebrew or machine-local dynamic-library paths are used.
