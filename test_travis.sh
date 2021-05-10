echo $ARCH
if [ "$ARCH" = "AARCH64" ]
then
  dub test --arch=aarch64 --build=unittest
else
  dub test --arch=$ARCH --build=unittest
fi
cd meson-example
meson build --default-library=static --buildtype=debug
ninja -C build
if [ "$TRAVIS_OS_NAME" = "osx" ]
then
  gcc test.c build/libion-example.dylib
else
  gcc test.c build/libion-example.so
LD_LIBRARY_PATH=build ./a.out
