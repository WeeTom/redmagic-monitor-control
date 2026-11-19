DDC frame regression tests (no hardware access)

Run from this source directory:
clang -fmodules -fsanitize=address -g -I headers -framework Foundation -framework IOKit tests/ddc_test.m sources/i2c.m -o /tmp/display-ddc-test
/tmp/display-ddc-test

Tests exercise decoding of a known valid frame, malformed response rejection,
requested-feature mismatch, checksum validation, and preserving zero-valued
checksum bytes on outgoing writes. I2C entry points are stubbed in the test.
