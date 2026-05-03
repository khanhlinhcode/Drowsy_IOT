#include "motion_detector.h"

#include <Wire.h>
#include <math.h>

namespace {
constexpr uint8_t MPU_REG_PWR_MGMT_1 = 0x6B;
constexpr uint8_t MPU_REG_ACCEL_XOUT_H = 0x3B;
constexpr uint8_t MPU_REG_WHO_AM_I = 0x75;
constexpr uint8_t MPU_EXPECTED_WHOAMI = 0x68;
}  // namespace

MotionDetector::MotionDetector() : _cfg() {}

MotionDetector::MotionDetector(const Config& config) : _cfg(config) {}

bool MotionDetector::begin() {
  Wire.begin();

  uint8_t who = 0;
  if (!readRegs(MPU_REG_WHO_AM_I, &who, 1)) {
    _available = false;
    _driving = false;
    return false;
  }

  if (who != MPU_EXPECTED_WHOAMI && who != 0x69) {
    _available = false;
    _driving = false;
    return false;
  }

  if (!writeReg(MPU_REG_PWR_MGMT_1, 0x00)) {
    _available = false;
    _driving = false;
    return false;
  }

  _available = true;
  _driving = false;
  _hasBaseline = false;
  _vibrationEma = 0.0f;
  _motionAboveThreshold = false;
  _motionAboveSinceMs = 0;
  _lastSampleMs = millis();
  _lastMotionMs = _lastSampleMs;
  return true;
}

void MotionDetector::tick(uint32_t nowMs) {
  if (!_available) {
    _driving = false;
    return;
  }

  if ((nowMs - _lastSampleMs) < _cfg.sampleIntervalMs) return;
  _lastSampleMs = nowMs;

  float ax = 0.0f;
  float ay = 0.0f;
  float az = 0.0f;
  if (!readAccel(ax, ay, az)) {
    // FIX #11: tolerate transient I2C failures (bus busy, noise, clock stretch).
    // Only mark unavailable after READ_FAIL_LIMIT consecutive failures.
    _readFailCount++;
    if (_readFailCount >= READ_FAIL_LIMIT) {
      _available = false;
      _driving = false;
    }
    return;
  }
  _readFailCount = 0;

  float mag = sqrtf((ax * ax) + (ay * ay) + (az * az));
  if (!_hasBaseline) {
    _baselineMag = mag;
    _hasBaseline = true;
  }

  // Slow baseline + faster vibration envelope.
  _baselineMag += 0.03f * (mag - _baselineMag);
  float vibration = fabsf(mag - _baselineMag);
  float emaPrev = _vibrationEma;
  // FIX: low-pass filtered vibration suppresses short road spikes.
  _vibrationEma += 0.25f * (vibration - _vibrationEma);
  // FIX: variance gate suppresses constant engine vibration false positives.
  float variance = fabsf(vibration - emaPrev);
  // FIX: trend gate only accepts rising motion envelopes.
  float trend = _vibrationEma - emaPrev;

  if (_vibrationEma > _cfg.motionThresholdG &&
      variance > _cfg.varianceThresholdG &&
      trend > 0.002f &&
      _vibrationEma > emaPrev) {
    if (!_motionAboveThreshold) {
      _motionAboveThreshold = true;
      _motionAboveSinceMs = nowMs;
    }
    // CRITICAL: only accept driving motion when vibration persists >2s.
    if ((nowMs - _motionAboveSinceMs) >= _cfg.motionPersistMs) {
      _lastMotionMs = nowMs;
    }
  } else {
    _motionAboveThreshold = false;
    _motionAboveSinceMs = 0;
  }

  _driving = (nowMs - _lastMotionMs) <= _cfg.drivingHoldMs;
}

bool MotionDetector::available() const { return _available; }

bool MotionDetector::isDriving() const { return _driving; }

float MotionDetector::vibrationLevel() const { return _vibrationEma; }

bool MotionDetector::writeReg(uint8_t reg, uint8_t value) {
  Wire.beginTransmission(_cfg.i2cAddress);
  Wire.write(reg);
  Wire.write(value);
  return Wire.endTransmission() == 0;
}

bool MotionDetector::readRegs(uint8_t reg, uint8_t* buf, size_t len) {
  if (buf == nullptr || len == 0) return false;

  Wire.beginTransmission(_cfg.i2cAddress);
  Wire.write(reg);
  if (Wire.endTransmission(false) != 0) {
    return false;
  }

  size_t readCount = Wire.requestFrom(static_cast<int>(_cfg.i2cAddress), static_cast<int>(len));
  if (readCount != len) {
    return false;
  }

  for (size_t i = 0; i < len; ++i) {
    buf[i] = static_cast<uint8_t>(Wire.read());
  }
  return true;
}

bool MotionDetector::readAccel(float& ax, float& ay, float& az) {
  uint8_t data[6];
  if (!readRegs(MPU_REG_ACCEL_XOUT_H, data, sizeof(data))) {
    return false;
  }

  int16_t rawX = static_cast<int16_t>((data[0] << 8) | data[1]);
  int16_t rawY = static_cast<int16_t>((data[2] << 8) | data[3]);
  int16_t rawZ = static_cast<int16_t>((data[4] << 8) | data[5]);

  // MPU6050 default accel scale: +/-2g => 16384 LSB/g
  ax = static_cast<float>(rawX) / 16384.0f;
  ay = static_cast<float>(rawY) / 16384.0f;
  az = static_cast<float>(rawZ) / 16384.0f;
  return true;
}
