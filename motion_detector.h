#ifndef MOTION_DETECTOR_H
#define MOTION_DETECTOR_H

#include <Arduino.h>

class MotionDetector {
 public:
struct Config {
  uint8_t i2cAddress = 0x68;
  uint32_t sampleIntervalMs = 25;

  // ổn định hơn bản nhạy
  float motionThresholdG = 0.08f;
  float varianceThresholdG = 0.012f;
  uint32_t motionPersistMs = 2000;
  uint32_t drivingHoldMs = 2500;
};
  explicit MotionDetector(const Config& config = Config());

  bool begin();
  void tick(uint32_t nowMs);

  bool available() const;
  bool isDriving() const;
  float vibrationLevel() const;

 private:
  Config _cfg;

  bool _available = false;
  bool _driving = true;  // Fail-safe: assume driving if sensor unavailable.

  uint32_t _lastSampleMs = 0;
  uint32_t _lastMotionMs = 0;

  bool _hasBaseline = false;
  float _baselineMag = 1.0f;
  float _vibrationEma = 0.0f;
  bool _motionAboveThreshold = false;
  uint32_t _motionAboveSinceMs = 0;
  // FIX #11: retry counter instead of immediate permanent disable.
  uint8_t _readFailCount = 0;
  static constexpr uint8_t READ_FAIL_LIMIT = 5;

  bool writeReg(uint8_t reg, uint8_t value);
  bool readRegs(uint8_t reg, uint8_t* buf, size_t len);
  bool readAccel(float& ax, float& ay, float& az);
};

#endif
