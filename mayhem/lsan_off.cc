// Disable LeakSanitizer at build time (ASan stays on): fleet policy for every ASan-built target.
extern "C" int __lsan_is_turned_off() { return 1; }
