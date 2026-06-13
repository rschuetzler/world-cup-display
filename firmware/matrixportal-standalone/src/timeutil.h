// Epoch-ms time source. After NTP locks, time(nullptr) returns real UTC.
#pragma once
#include <stdint.h>
#include <sys/time.h>
#include <time.h>

// Current UTC epoch milliseconds.
inline int64_t nowEpochMs() {
  struct timeval tv;
  gettimeofday(&tv, nullptr);
  return (int64_t)tv.tv_sec * 1000LL + tv.tv_usec / 1000LL;
}

// Whether NTP has locked (time is past ~2023-11). Before this, epoch is bogus.
inline bool timeSynced() { return time(nullptr) > 1700000000; }
