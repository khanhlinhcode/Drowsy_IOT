#include <ArduinoJson.h>
#include <PubSubClient.h>
#include <WiFi.h>
#include <ctype.h>
#include <string.h>

#include "motion_detector.h"
#include "wifi_manager.h"

// Set to 1 for verbose per-message MQTT logging (adds ~8ms/msg).
// Keep 0 for production to minimize buzzer timing jitter.
#define VERBOSE 0

// ============================================================
// Configuration
// ============================================================
const char* MQTT_HOST = "192.168.0.163";
const uint16_t MQTT_PORT = 1883;
const char* MQTT_CLIENT_ID_BASE = "esp32-drowsy-alert";
const char* MQTT_TOPIC_STATUS = "driver/status";
const char* MQTT_TOPIC_META = "driver/status_meta";
const char* MQTT_TOPIC_CMD = "driver/cmd";

// Pins
const uint8_t PIN_LED_GREEN = 21;
const uint8_t PIN_LED_RED = 19;
const uint8_t PIN_LED_BLUE = 22;
const uint8_t PIN_BUZZER = 23;
const uint8_t PIN_SPEAKER = 25;
const uint8_t PIN_WIFI_RESET_BUTTON = 0;  // GPIO 0 = BOOT button

// WiFi reset button timing (Method A)
const uint32_t WIFI_RESET_HOLD_MS = 5000;  // 5-second long-press

const bool LED_ACTIVE_LOW = false;
const bool BUZZER_ACTIVE_LOW = true;
const bool USE_ACTIVE_BUZZER = true;
const bool USE_PASSIVE_SPEAKER = true;

const uint8_t LED_ON_LEVEL = LED_ACTIVE_LOW ? LOW : HIGH;
const uint8_t LED_OFF_LEVEL = LED_ACTIVE_LOW ? HIGH : LOW;
const uint8_t BUZZER_ON_LEVEL = BUZZER_ACTIVE_LOW ? LOW : HIGH;
const uint8_t BUZZER_OFF_LEVEL = BUZZER_ACTIVE_LOW ? HIGH : LOW;

const uint8_t SPEAKER_LEDC_CH = 0;
const uint8_t SPEAKER_LEDC_BITS = 8;
const uint16_t SPEAKER_LEDC_BASE_FREQ = 2200;

// MQTT reliability
const uint32_t MQTT_RETRY_BASE_MS = 250;
const uint32_t MQTT_RETRY_MAX_MS = 5000;
const uint32_t MQTT_SUB_RETRY_MS = 900;
const uint32_t MQTT_BACKOFF_CAP_MS = 8000;
const uint8_t MQTT_RETRY_LIMIT = 5;
const uint32_t ALERT_STATE_DEBOUNCE_MS = 100;
const uint32_t MQTT_PACKET_LATE_ALLOW_MS = 2000;
const uint32_t MQTT_SYNC_FRESH_MS = 2000;
const uint32_t STATUS_DUP_GAP_MS = 80;
const uint32_t STATUS_FALLBACK_BLOCK_MS = 700;

// Data freshness / watchdog
const uint32_t DEFAULT_TTL_MS = 3000;
const uint32_t MIN_TTL_MS = 1200;
const uint32_t MAX_TTL_MS = 10000;

// State timing
const uint32_t STABLE_RISE_TIRED_MS = 320;
const uint32_t STABLE_RISE_SLEEPY_MS = 3000;   // SLEEPY persist >= 3s
const uint32_t STABLE_FALL_MS = 1100;
const uint32_t CONFIRMED_STATE_HOLD_MS = 180;
const uint32_t SLEEP_CONTINUOUS_MIN_MS = 5000;  // Continuous alarm >= 5s
// FIX #6: hard timeout to force-reset dangerous state when MQTT is dead.
const uint32_t WATCHDOG_HARD_TIMEOUT_MS = 30000;
const uint32_t ESP_TELEMETRY_MS = 1000;
const char* MQTT_TOPIC_ESP_TELEMETRY = "driver/esp32_telemetry";

const uint32_t LOG_GAP_MS = 1500;

WiFiClient gWifi;
PubSubClient gMqtt(gWifi);
WifiManager gWifiManager;
MotionDetector gMotionDetector;

// ============================================================
// State machine
// ============================================================
enum class AiState : uint8_t {
  SAFE = 0,
  TIRED = 1,
  SLEEPY = 2,
  SLEEP = 3,
};

enum class SystemState : uint8_t {
  SAFE = 0,
  DRIVING = 1,
  TIRED = 2,
  SLEEPY = 3,
  SLEEP = 4,
};

enum class AlertMode : uint8_t {
  OFF = 0,
  DRIVING_DOUBLE_BEEP,
  TIRED_SLOW_BEEP,
  SLEEPY_FAST_BEEP,
  SLEEP_CONTINUOUS,
};

struct RxPacket {
  bool valid = false;
  bool fromMeta = false;
  AiState aiState = AiState::SAFE;
  int fatigue = 0;
  bool hasSeq = false;
  uint64_t seq = 0;
  bool hasTs = false;
  uint64_t tsMs = 0;
  bool hasPublishTs = false;
  uint64_t publishTsMs = 0;
  bool hasTtl = false;
  uint32_t ttlMs = DEFAULT_TTL_MS;
};

AiState gRawAiState = AiState::SAFE;
SystemState gObservedState = SystemState::SAFE;
SystemState gStableState = SystemState::SAFE;
SystemState gConfirmedState = SystemState::SAFE;
SystemState gConfirmCandidate = SystemState::SAFE;
uint32_t gConfirmCandidateSinceMs = 0;
SystemState gCandidateState = SystemState::SAFE;
uint32_t gCandidateSinceMs = 0;
uint32_t gStableSinceMs = 0;

uint32_t gLastRxMs = 0;
uint32_t gCurrentTtlMs = DEFAULT_TTL_MS;

bool gHasSeq = false;
uint64_t gLastSeq = 0;
bool gHasTs = false;
uint64_t gLastTsMs = 0;
uint32_t gLastTsArrivalMs = 0;
uint32_t gLastMetaRxMs = 0;
bool gNeedSyncAfterReconnect = true;
uint32_t gLastRxMetaTsMs = 0;

AiState gLastStatusFallbackAi = AiState::SAFE;
uint32_t gLastStatusFallbackMs = 0;

bool gMqttUp = false;
bool gMqttSubscribed = false;
bool gPrevMqttConnected = false;
uint32_t gMqttBackoffMs = MQTT_RETRY_BASE_MS;
uint32_t gNextMqttTryMs = 0;
uint32_t gNextSubTryMs = 0;
uint8_t gMqttRetryCount = 0;
uint8_t gMqttSubRetryCount = 0;
bool gFirstPacketReceived = false;
uint32_t gReconnectCount = 0;
char gClientId[64] = {0};

// WiFi reset button state (Method A: GPIO 0 long-press)
bool gButtonPressed = false;
uint32_t gButtonPressedSinceMs = 0;
bool gButtonResetFired = false;  // prevent repeated triggers while held

// Startup alert pattern
bool gStartupActive = true;
uint8_t gStartupStep = 0;
uint32_t gStartupStepUntilMs = 0;

// Alert scheduler
AlertMode gAlertMode = AlertMode::OFF;
bool gAlarmOn = false;
bool gIsBeeping = false;   // FIX: prevent buzzer overlap/glitch from repeated tone() calls.
uint16_t gToneHz = 0;
uint8_t gPatternStep = 0;
uint32_t gPatternUntilMs = 0;
uint32_t gSleepAlarmLockUntilMs = 0;
uint32_t gLastSleepTimeMs = 0;
bool gHasLastSleepTime = false;
SystemState gLastAlertState = SystemState::SAFE;
uint32_t gLastStateChangeMs = 0;
uint32_t gLastTelemetryMs = 0;
uint32_t gPacketCountWindow = 0;
uint32_t gPacketRateMarkMs = 0;
float gPacketRateHz = 0.0f;
uint32_t gPacketLossCount = 0;
float gLatencyAvgMs = 0.0f;
uint32_t gLatencySamples = 0;
uint32_t gLastLatencyTotalMs = 0;
uint32_t gLastPublishToEspMs = 0;
uint32_t gLastEspToAlertMs = 0;
uint32_t gLastAlertEdgeMs = 0;
uint32_t gLastEspReceiveTsMs = 0;

uint32_t gLastLogMs = 0;

// ============================================================
// Utility
// ============================================================
int stateLevel(SystemState s) { return static_cast<int>(s); }

bool isDangerous(SystemState s) { return stateLevel(s) >= stateLevel(SystemState::SLEEPY); }

const char* aiStateName(AiState s) {
  switch (s) {
    case AiState::SAFE:
      return "SAFE";
    case AiState::TIRED:
      return "TIRED";
    case AiState::SLEEPY:
      return "SLEEPY";
    case AiState::SLEEP:
      return "SLEEP";
  }
  return "SAFE";
}

const char* systemStateName(SystemState s) {
  switch (s) {
    case SystemState::SAFE:
      return "SAFE";
    case SystemState::DRIVING:
      return "DRIVING";
    case SystemState::TIRED:
      return "TIRED";
    case SystemState::SLEEPY:
      return "SLEEPY";
    case SystemState::SLEEP:
      return "SLEEP";
  }
  return "SAFE";
}

int clampFatigue(int f) {
  if (f < 0) return 0;
  if (f > 100) return 100;
  return f;
}

uint32_t clampTtlMs(uint32_t ttl) {
  if (ttl < MIN_TTL_MS) return MIN_TTL_MS;
  if (ttl > MAX_TTL_MS) return MAX_TTL_MS;
  return ttl;
}

bool equalsIgnoreCase(const char* a, const char* b) {
  if (a == nullptr || b == nullptr) return false;
  while (*a != '\0' && *b != '\0') {
    if (tolower(static_cast<unsigned char>(*a)) != tolower(static_cast<unsigned char>(*b))) {
      return false;
    }
    a++;
    b++;
  }
  return (*a == '\0' && *b == '\0');
}

bool parseIntStrict(const char* text, int* out) {
  if (text == nullptr || out == nullptr) return false;
  while (*text == ' ' || *text == '\t') text++;
  if (*text == '\0') return false;

  bool neg = false;
  if (*text == '-') {
    neg = true;
    text++;
  }
  if (*text < '0' || *text > '9') return false;

  long value = 0;
  while (*text >= '0' && *text <= '9') {
    value = value * 10L + static_cast<long>(*text - '0');
    text++;
  }

  while (*text == ' ' || *text == '\t') text++;
  if (*text != '\0') return false;

  if (neg) value = -value;
  *out = static_cast<int>(value);
  return true;
}

AiState mapSignalToAiState(int signal) {
  if (signal <= 0) return AiState::SAFE;
  if (signal == 1) return AiState::TIRED;
  if (signal == 2) return AiState::SLEEPY;
  return AiState::SLEEP;
}

AiState mapStatusTextToAiState(const char* statusText, bool* ok) {
  if (ok != nullptr) *ok = true;
  if (statusText == nullptr || statusText[0] == '\0') {
    if (ok != nullptr) *ok = false;
    return AiState::SAFE;
  }

  if (equalsIgnoreCase(statusText, "MICROSLEEP") || equalsIgnoreCase(statusText, "SLEEP")) {
    return AiState::SLEEP;
  }
  if (equalsIgnoreCase(statusText, "SLEEPY") || equalsIgnoreCase(statusText, "LOOKING DOWN")) {
    return AiState::SLEEPY;
  }
  if (equalsIgnoreCase(statusText, "TIRED")) {
    return AiState::TIRED;
  }
  if (equalsIgnoreCase(statusText, "ATTENTIVE") || equalsIgnoreCase(statusText, "NORMAL")) {
    return AiState::SAFE;
  }

  if (ok != nullptr) *ok = false;
  return AiState::SAFE;
}

SystemState deriveObservedState(AiState aiState, bool driving) {
  if (aiState == AiState::SLEEP) return SystemState::SLEEP;

  if (!driving) return SystemState::SAFE;   // không chạy xe => im

  switch (aiState) {
    case AiState::SAFE:   return SystemState::DRIVING; // nhìn thẳng + chạy => bíp bíp
    case AiState::TIRED:  return SystemState::TIRED;
    case AiState::SLEEPY: return SystemState::SLEEPY;
    case AiState::SLEEP:  return SystemState::SLEEP;
  }
  return SystemState::SAFE;

}


void logTransition(SystemState fromState, SystemState toState) {
  Serial.print("STATE ");
  Serial.print(systemStateName(fromState));
  Serial.print(" -> ");
  Serial.println(systemStateName(toState));
}

// ============================================================
// Output control (non-blocking)
// ============================================================
void setLeds(bool greenOn, bool redOn, bool blueOn) {
  digitalWrite(PIN_LED_GREEN, greenOn ? LED_ON_LEVEL : LED_OFF_LEVEL);
  digitalWrite(PIN_LED_RED, redOn ? LED_ON_LEVEL : LED_OFF_LEVEL);
  digitalWrite(PIN_LED_BLUE, blueOn ? LED_ON_LEVEL : LED_OFF_LEVEL);
}

void setAlarm(bool on, uint16_t toneHz) {
  gAlarmOn = on;

  // FIX: guard speaker/buzzer start to avoid overlapping tone activations.
  if (on) {
    if (!gIsBeeping) {
      if (USE_ACTIVE_BUZZER) {
        digitalWrite(PIN_BUZZER, BUZZER_ON_LEVEL);
      }
      if (USE_PASSIVE_SPEAKER && toneHz > 0) {
        ledcWriteTone(SPEAKER_LEDC_CH, toneHz);
      }
      gIsBeeping = true;
      gToneHz = toneHz;
      return;
    }
    if (USE_PASSIVE_SPEAKER && toneHz > 0 && toneHz != gToneHz) {
      ledcWriteTone(SPEAKER_LEDC_CH, toneHz);
      gToneHz = toneHz;
    }
    return;
  }

  if (gIsBeeping) {
    if (USE_ACTIVE_BUZZER) {
      digitalWrite(PIN_BUZZER, BUZZER_OFF_LEVEL);
    }
    if (USE_PASSIVE_SPEAKER) {
      ledcWriteTone(SPEAKER_LEDC_CH, 0);
    }
    gIsBeeping = false;
    gToneHz = 0;
  } else if (USE_ACTIVE_BUZZER) {
    digitalWrite(PIN_BUZZER, BUZZER_OFF_LEVEL);
  }
}

void resetPatternScheduler(uint32_t nowMs) {
  gPatternStep = 0;
  gPatternUntilMs = nowMs;
  setAlarm(false, 0);
}

void runSingleBeepPattern(uint32_t nowMs, uint16_t toneHz, uint16_t onMs, uint16_t offMs) {
  if (nowMs < gPatternUntilMs) return;

  if (!gAlarmOn) {
    setAlarm(true, toneHz);
    gPatternUntilMs = nowMs + onMs;
  } else {
    setAlarm(false, 0);
    gPatternUntilMs = nowMs + offMs;
  }
}

// FIX: Driving pattern tuned to ~1.2s cycle: beep-beep then pause.
void runDoubleBeepPattern(uint32_t nowMs, uint16_t toneHz) {
  if (nowMs < gPatternUntilMs) return;

  switch (gPatternStep) {
    case 0:
      setAlarm(true, toneHz);
      gPatternUntilMs = nowMs + 70;
      gPatternStep = 1;
      break;
    case 1:
      setAlarm(false, 0);
      gPatternUntilMs = nowMs + 90;
      gPatternStep = 2;
      break;
    case 2:
      setAlarm(true, toneHz);
      gPatternUntilMs = nowMs + 70;
      gPatternStep = 3;
      break;
    default:
      setAlarm(false, 0);
      gPatternUntilMs = nowMs + 970;
      gPatternStep = 0;
      break;
  }
}

bool runStartupSequence(uint32_t nowMs) {
  if (!gStartupActive) return false;
  if (isDangerous(gStableState)) {
    gStartupActive = false;
    setAlarm(false, 0);
    return false;
  }
  if (nowMs < gStartupStepUntilMs) return true;

  switch (gStartupStep) {
    case 0:
      setLeds(false, false, true);
      setAlarm(true, 2300);
      // IMPROVE: startup total duration ~1s (beep beep beep).
      gStartupStepUntilMs = nowMs + 120;
      gStartupStep = 1;
      return true;
    case 1:
      setAlarm(false, 0);
      gStartupStepUntilMs = nowMs + 100;
      gStartupStep = 2;
      return true;
    case 2:
      setAlarm(true, 2300);
      gStartupStepUntilMs = nowMs + 120;
      gStartupStep = 3;
      return true;
    case 3:
      setAlarm(false, 0);
      gStartupStepUntilMs = nowMs + 100;
      gStartupStep = 4;
      return true;
    case 4:
      setAlarm(true, 2300);
      gStartupStepUntilMs = nowMs + 120;
      gStartupStep = 5;
      return true;
    case 5:
      // CRITICAL: hold final silence so startup sequence is ~1 second total.
      setAlarm(false, 0);
      gStartupStepUntilMs = nowMs + 440;
      gStartupStep = 6;
      return true;
    default:
      setAlarm(false, 0);
      setLeds(true, false, false);
      gStartupActive = false;
      return false;
  }
}

AlertMode resolveAlertMode(uint32_t nowMs) {
  const SystemState alertState = gLastAlertState;
  // CRITICAL: hard-lock sleep alarm for >=5s independent from stream gaps.
  const bool withinSleepLock = gHasLastSleepTime && (nowMs - gLastSleepTimeMs) < SLEEP_CONTINUOUS_MIN_MS;
  if (alertState == SystemState::SLEEP || withinSleepLock || nowMs < gSleepAlarmLockUntilMs) {
    return AlertMode::SLEEP_CONTINUOUS;
  }

  switch (alertState) {
    case SystemState::SAFE:
      return AlertMode::OFF;
    case SystemState::DRIVING:
      return AlertMode::DRIVING_DOUBLE_BEEP;
    case SystemState::TIRED:
      return AlertMode::TIRED_SLOW_BEEP;
    case SystemState::SLEEPY:
      return AlertMode::SLEEPY_FAST_BEEP;
    case SystemState::SLEEP:
      return AlertMode::SLEEP_CONTINUOUS;
  }
  return AlertMode::OFF;
}

void applyLedsForState() {
  switch (gLastAlertState) {
    case SystemState::SAFE:
      setLeds(true, false, false);
      break;
    case SystemState::DRIVING:
      setLeds(false, false, true);
      break;
    case SystemState::TIRED:
      setLeds(true, false, true);
      break;
    case SystemState::SLEEPY:
      setLeds(gAlarmOn, gAlarmOn, false);
      break;
    case SystemState::SLEEP:
      setLeds(false, true, false);
      break;
  }
}

void updateAlertEngine(uint32_t nowMs) {
  if (runStartupSequence(nowMs)) return;

  if (gStableState != gLastAlertState &&
      (nowMs - gLastStateChangeMs) > ALERT_STATE_DEBOUNCE_MS &&
      gStableState == gConfirmedState) {
    // FIX: debounce state change and reset buzzer safely.
    // FIX #4: noTone() can conflict with LEDC channels; use direct GPIO.
    digitalWrite(PIN_BUZZER, BUZZER_OFF_LEVEL);
    if (USE_PASSIVE_SPEAKER) {
      ledcWriteTone(SPEAKER_LEDC_CH, 0);
    }
    gIsBeeping = false;
    gAlarmOn = false;
    gToneHz = 0;

    gLastAlertState = gStableState;
    gLastStateChangeMs = nowMs;
  }

  AlertMode nextMode = resolveAlertMode(nowMs);
  if (nextMode != gAlertMode) {
    AlertMode prevMode = gAlertMode;
    gAlertMode = nextMode;
    resetPatternScheduler(nowMs);
    if (static_cast<int>(gAlertMode) >= static_cast<int>(AlertMode::TIRED_SLOW_BEEP)) {
      gLastAlertEdgeMs = nowMs;
      gLastEspToAlertMs = nowMs - gLastRxMs;
      Serial.print("[ALERT] triggered=");
      Serial.print(static_cast<int>(gAlertMode));
      Serial.print(" prev=");
      Serial.print(static_cast<int>(prevMode));
      Serial.print(" esp_to_alert=");
      Serial.println(gLastEspToAlertMs);
    }
  }

  switch (gAlertMode) {
    case AlertMode::OFF:
      setAlarm(false, 0);
      break;
    case AlertMode::DRIVING_DOUBLE_BEEP:
      runDoubleBeepPattern(nowMs, 1600);
      break;
    case AlertMode::TIRED_SLOW_BEEP:
      runSingleBeepPattern(nowMs, 1650, 120, 880);
      break;
    case AlertMode::SLEEPY_FAST_BEEP:
      // FIX: Sleepy pattern ~600ms period.
      runSingleBeepPattern(nowMs, 2100, 120, 480);
      break;
    case AlertMode::SLEEP_CONTINUOUS:
      setAlarm(true, 2600);
      break;
  }

  applyLedsForState();
}

// ============================================================
// MQTT parser + validation
// ============================================================
bool topicMatches(const char* got, const char* expected) {
  if (got == nullptr || expected == nullptr) return false;
  if (strcmp(got, expected) == 0) return true;
  if (got[0] == '/' && strcmp(got + 1, expected) == 0) return true;
  if (expected[0] == '/' && strcmp(got, expected + 1) == 0) return true;
  return false;
}

bool parseStatusTopic(const char* payload, RxPacket* out) {
  if (payload == nullptr || out == nullptr) return false;
  int sig = 0;
  if (!parseIntStrict(payload, &sig)) return false;

  out->valid = true;
  out->fromMeta = false;
  out->aiState = mapSignalToAiState(sig);
  out->fatigue = 0;
  out->hasSeq = false;
  out->hasTs = false;
  out->hasTtl = false;
  return true;
}

bool parseMetaTopic(const char* payload, RxPacket* out) {
  if (payload == nullptr || out == nullptr) return false;

  StaticJsonDocument<384> doc;
  DeserializationError err = deserializeJson(doc, payload);
  if (err) return false;

  bool stateOk = false;
  AiState aiState = AiState::SAFE;

  if (doc["signal"].is<int>()) {
    aiState = mapSignalToAiState(doc["signal"].as<int>());
    stateOk = true;
  } else if (doc["status"].is<const char*>()) {
    bool ok = false;
    aiState = mapStatusTextToAiState(doc["status"].as<const char*>(), &ok);
    stateOk = ok;
  }
  if (!stateOk) return false;

  RxPacket pkt;
  pkt.valid = true;
  pkt.fromMeta = true;
  pkt.aiState = aiState;
  pkt.fatigue = doc["fatigue"].is<int>() ? clampFatigue(doc["fatigue"].as<int>()) : 0;

  if (doc["seq"].is<uint64_t>()) {
    pkt.hasSeq = true;
    pkt.seq = doc["seq"].as<uint64_t>();
  }
  if (doc["ts_ms"].is<uint64_t>()) {
    pkt.hasTs = true;
    pkt.tsMs = doc["ts_ms"].as<uint64_t>();
  }
  if (doc["publish_ts_ms"].is<uint64_t>()) {
    pkt.hasPublishTs = true;
    pkt.publishTsMs = doc["publish_ts_ms"].as<uint64_t>();
  }
  if (doc["ttl_ms"].is<unsigned long>()) {
    pkt.hasTtl = true;
    pkt.ttlMs = static_cast<uint32_t>(doc["ttl_ms"].as<unsigned long>());
  }

  if (!pkt.hasSeq || !pkt.hasTs) return false;

  *out = pkt;
  return true;
}

void resetMetaOrderingState() {
  gHasSeq = false;
  gHasTs = false;
}

bool validatePacket(const RxPacket& pkt, uint32_t nowMs) {
  if (!pkt.valid) return false;

  if (pkt.fromMeta) {
    if (gNeedSyncAfterReconnect) return true;

    const bool staleGap = (nowMs - gLastRxMs) > gCurrentTtlMs;

    if (pkt.hasSeq && gHasSeq && pkt.seq <= gLastSeq) {
      if (!staleGap) return false;
      resetMetaOrderingState();
    }

    if (pkt.hasTs && gHasTs && pkt.tsMs <= gLastTsMs) {
      if (!staleGap) return false;
      resetMetaOrderingState();
    }

    if (pkt.hasTs && gHasTs) {
      uint64_t sourceDelta = pkt.tsMs - gLastTsMs;
      uint32_t arrivalDelta = nowMs - gLastTsArrivalMs;
      if (static_cast<uint64_t>(arrivalDelta) > (sourceDelta + MQTT_PACKET_LATE_ALLOW_MS)) {
        return false;
      }
    }
    return true;
  }

  // status topic fallback only when meta stream is not active.
  if ((nowMs - gLastMetaRxMs) <= STATUS_FALLBACK_BLOCK_MS) return false;
  if (pkt.aiState == gLastStatusFallbackAi && (nowMs - gLastStatusFallbackMs) < STATUS_DUP_GAP_MS) return false;
  return true;
}

void acceptPacket(const RxPacket& pkt, uint32_t nowMs) {
  gFirstPacketReceived = true;
  gPacketCountWindow++;
  if (gPacketRateMarkMs == 0) {
    gPacketRateMarkMs = nowMs;
  } else {
    uint32_t elapsed = nowMs - gPacketRateMarkMs;
    if (elapsed >= 1000) {
      gPacketRateHz = (gPacketCountWindow * 1000.0f) / max(1UL, elapsed);
      gPacketCountWindow = 0;
      gPacketRateMarkMs = nowMs;
    }
  }

  if (pkt.fromMeta) {
    if (pkt.hasSeq) {
      if (gHasSeq && pkt.seq > (gLastSeq + 1)) {
        gPacketLossCount += static_cast<uint32_t>(pkt.seq - gLastSeq - 1);
      }
      gHasSeq = true;
      gLastSeq = pkt.seq;
    }
    if (pkt.hasTs) {
      gHasTs = true;
      gLastTsMs = pkt.tsMs;
      gLastTsArrivalMs = nowMs;
      gLastRxMetaTsMs = static_cast<uint32_t>(pkt.tsMs & 0xFFFFFFFFu);
    }
    if (pkt.hasTtl) {
      gCurrentTtlMs = clampTtlMs(pkt.ttlMs);
    }
    gLastMetaRxMs = nowMs;
  } else {
    gLastStatusFallbackAi = pkt.aiState;
    gLastStatusFallbackMs = nowMs;
  }

  gLastRxMs = nowMs;
  gRawAiState = pkt.aiState;
}

// ============================================================
// State smoothing and watchdog
// ============================================================
void setStableState(SystemState nextState, uint32_t nowMs) {
  if (nextState == gStableState) {
    gCandidateState = nextState;
    gCandidateSinceMs = nowMs;
    return;
  }

  SystemState prev = gStableState;
  gStableState = nextState;
  gStableSinceMs = nowMs;
  gCandidateState = nextState;
  gCandidateSinceMs = nowMs;
  Serial.print("[STATE] transition=");
  Serial.print(systemStateName(prev));
  Serial.print("->");
  Serial.println(systemStateName(nextState));
}

void updateConfirmedState(uint32_t nowMs) {
  if (gStableState == gConfirmedState) {
    gConfirmCandidate = gStableState;
    gConfirmCandidateSinceMs = nowMs;
    return;
  }
  if (gStableState != gConfirmCandidate) {
    gConfirmCandidate = gStableState;
    gConfirmCandidateSinceMs = nowMs;
    return;
  }
  if ((nowMs - gConfirmCandidateSinceMs) >= CONFIRMED_STATE_HOLD_MS) {
    gConfirmedState = gConfirmCandidate;
  }
}

void applyObservation(SystemState observed, uint32_t nowMs) {
  gObservedState = observed;

  // NORMAL/DRIVING reset immediately.
  if (observed == SystemState::SAFE || observed == SystemState::DRIVING) {
    setStableState(observed, nowMs);
    return;
  }

  // SLEEP immediate + enforce continuous alarm minimum.
  if (observed == SystemState::SLEEP) {
    setStableState(SystemState::SLEEP, nowMs);
    const uint32_t lockUntil = nowMs + SLEEP_CONTINUOUS_MIN_MS;
    if (!gHasLastSleepTime || nowMs >= gSleepAlarmLockUntilMs) {
      gHasLastSleepTime = true;
      gLastSleepTimeMs = nowMs;
      gSleepAlarmLockUntilMs = lockUntil;
    } else {
      // FIX #9: use max (not min) so repeated SLEEP packets don't shorten alarm.
      // Cap at 2x to prevent indefinite prolongation.
      gSleepAlarmLockUntilMs = min(max(gSleepAlarmLockUntilMs, lockUntil),
                                   nowMs + SLEEP_CONTINUOUS_MIN_MS * 2);
    }
    return;
  }

  if (observed == gStableState) {
    gCandidateState = observed;
    gCandidateSinceMs = nowMs;
    return;
  }

  int cur = stateLevel(gStableState);
  int obs = stateLevel(observed);

  if (obs > cur) {
    if (gCandidateState != observed) {
      gCandidateState = observed;
      gCandidateSinceMs = nowMs;
      return;
    }

    uint32_t needMs = (observed == SystemState::TIRED) ? STABLE_RISE_TIRED_MS : STABLE_RISE_SLEEPY_MS;
    if ((nowMs - gCandidateSinceMs) >= needMs) {
      setStableState(observed, nowMs);
    }
    return;
  }

  if (gCandidateState != observed) {
    gCandidateState = observed;
    gCandidateSinceMs = nowMs;
    return;
  }

  if ((nowMs - gCandidateSinceMs) >= STABLE_FALL_MS) {
    setStableState(observed, nowMs);
  }
}

void applyDataWatchdog(uint32_t nowMs) {
  uint32_t age = nowMs - gLastRxMs;
  if (age <= gCurrentTtlMs) return;

  // FIX #6: hard timeout — if MQTT is dead > 30s, force reset even from
  // dangerous state. Without this, SLEEPY/SLEEP keeps buzzer on forever.
  if (isDangerous(gStableState) && age < WATCHDOG_HARD_TIMEOUT_MS) return;

  bool driving = gMotionDetector.isDriving();
  setStableState(driving ? SystemState::DRIVING : SystemState::SAFE, nowMs);
}

// ============================================================
// MQTT connectivity
// ============================================================
const char* buildClientId() {
  uint64_t chip = ESP.getEfuseMac();
  snprintf(gClientId, sizeof(gClientId), "%s-%08X", MQTT_CLIENT_ID_BASE,
           static_cast<uint32_t>(chip & 0xFFFFFFFFu));
  return gClientId;
}

bool subscribeTopics() {
  // FIX #3: evaluate both subscribes independently to avoid || short-circuit
  // skipping the second topic variant.
  bool s1 = gMqtt.subscribe(MQTT_TOPIC_STATUS, 1);
  bool s2 = gMqtt.subscribe("/driver/status", 1);
  bool statusOk = s1 || s2;

  bool m1 = gMqtt.subscribe(MQTT_TOPIC_META, 1);
  bool m2 = gMqtt.subscribe("/driver/status_meta", 1);
  bool metaOk = m1 || m2;

  // Method B: subscribe to command topic for remote WiFi reset
  bool c1 = gMqtt.subscribe(MQTT_TOPIC_CMD, 1);
  bool c2 = gMqtt.subscribe("/driver/cmd", 1);
  bool cmdOk = c1 || c2;

  if (!statusOk) {
    Serial.println("MQTT SUB FAIL: driver/status");
    return false;
  }
  if (!metaOk) {
    Serial.println("MQTT SUB WARN: driver/status_meta");
  }
  if (!cmdOk) {
    Serial.println("MQTT SUB WARN: driver/cmd");
  }
  return true;
}

// ============================================================
// Method A: WiFi reset via long-press button (GPIO 0, 5 seconds)
// ============================================================
void checkWifiResetButton(uint32_t nowMs) {
  bool pressed = (digitalRead(PIN_WIFI_RESET_BUTTON) == LOW);

  if (pressed) {
    if (!gButtonPressed) {
      // Button just pressed — record start time.
      gButtonPressed = true;
      gButtonPressedSinceMs = nowMs;
      gButtonResetFired = false;
    } else if (!gButtonResetFired && (nowMs - gButtonPressedSinceMs) >= WIFI_RESET_HOLD_MS) {
      // Held for >= 5 seconds — trigger WiFi portal reset.
      Serial.println("[BUTTON] WiFi reset triggered (5s hold)");
      gWifiManager.openPortal();
      gButtonResetFired = true;  // Prevent repeated triggers while held.
    }
  } else {
    gButtonPressed = false;
    gButtonResetFired = false;
  }
}

// ============================================================
// Method B: WiFi reset via remote MQTT command (driver/cmd)
// ============================================================
void handleCommandMessage(const char* msg) {
  StaticJsonDocument<256> doc;
  DeserializationError err = deserializeJson(doc, msg);
  if (err) {
    Serial.print("[CMD] JSON parse error: ");
    Serial.println(err.c_str());
    return;
  }

  const char* action = doc["action"].as<const char*>();
  if (action == nullptr) {
    Serial.println("[CMD] missing action field");
    return;
  }

  if (equalsIgnoreCase(action, "reset_wifi")) {
    Serial.println("[CMD] Remote WiFi reset requested");
    gWifiManager.openPortal();
  } else if (equalsIgnoreCase(action, "clear_wifi")) {
    Serial.println("[CMD] Remote WiFi clear requested");
    gWifiManager.clearCredentials();
  } else {
    Serial.print("[CMD] Unknown action: ");
    Serial.println(action);
  }
}

void onMqttMessage(char* topic, uint8_t* payload, unsigned int length) {
  // Route command messages to dedicated handler.
  if (topicMatches(topic, MQTT_TOPIC_CMD)) {
    char cmdMsg[260];
    unsigned int cn = length;
    if (cn >= sizeof(cmdMsg)) cn = sizeof(cmdMsg) - 1;
    if (payload != nullptr && cn > 0) memcpy(cmdMsg, payload, cn);
    cmdMsg[cn] = '\0';
    Serial.print("[CMD] MQTT[");
    Serial.print(topic);
    Serial.print("]: ");
    Serial.println(cmdMsg);
    handleCommandMessage(cmdMsg);
    return;
  }

  if (!(topicMatches(topic, MQTT_TOPIC_STATUS) || topicMatches(topic, MQTT_TOPIC_META))) {
    return;
  }

  char msg[380];
  unsigned int n = length;
  if (n >= sizeof(msg)) n = sizeof(msg) - 1;
  if (payload != nullptr && n > 0) {
    memcpy(msg, payload, n);
  }
  msg[n] = '\0';

#if VERBOSE
  Serial.print("RAW MQTT[");
  Serial.print(topic);
  Serial.print("]: ");
  Serial.println(msg);
#endif

  RxPacket pkt;
  bool parsed = false;
  if (topicMatches(topic, MQTT_TOPIC_META)) {
    parsed = parseMetaTopic(msg, &pkt);
  } else {
    parsed = parseStatusTopic(msg, &pkt);
  }
  if (!parsed || !pkt.valid) return;

  uint32_t nowMs = millis();
  if (!validatePacket(pkt, nowMs)) return;

  gLastEspReceiveTsMs = nowMs;

  // FIX #2: ts_ms is RPi monotonic clock; millis() is ESP32 monotonic clock.
  // These are DIFFERENT clock domains — subtraction is meaningless.
  // Only track inter-packet delta as a staleness proxy.
  if (pkt.hasTs) {
    if (gHasTs && pkt.tsMs > gLastTsMs) {
      // Source-side inter-packet interval (valid within RPi clock domain)
      uint64_t srcDelta = pkt.tsMs - gLastTsMs;
      gLastLatencyTotalMs = static_cast<uint32_t>(srcDelta & 0xFFFFFFFFu);
    } else {
      gLastLatencyTotalMs = 0;
    }
    gLatencySamples++;
    gLatencyAvgMs += (static_cast<float>(gLastLatencyTotalMs) - gLatencyAvgMs) / static_cast<float>(max(1UL, gLatencySamples));
  }
  if (pkt.hasPublishTs && gHasTs) {
    // publish_ts_ms - ts_ms = RPi-side publish delay (same clock domain, valid)
    uint32_t rpiPublishDelay = static_cast<uint32_t>((pkt.publishTsMs - pkt.tsMs) & 0xFFFFFFFFu);
    gLastPublishToEspMs = rpiPublishDelay;
  }
#if VERBOSE
  Serial.print("[MQTT] src_delta=");
  Serial.print(gLastLatencyTotalMs);
  Serial.print(" rpi_pub_delay=");
  Serial.println(gLastPublishToEspMs);
#endif

  acceptPacket(pkt, nowMs);
  bool driving = gMotionDetector.isDriving();
  SystemState observed = deriveObservedState(pkt.aiState, driving);
  applyObservation(observed, nowMs);
}

void ensureMqtt(uint32_t nowMs) {
  if (!gWifiManager.isConnected()) {
    // FIX: force MQTT reset immediately when WiFi is not in connected state.
    if (gMqtt.connected()) {
      gMqtt.disconnect();
    }
    gMqttUp = false;
    gMqttSubscribed = false;
    gFirstPacketReceived = false;
    gNeedSyncAfterReconnect = true;
    return;
  }

  if (gMqtt.connected()) {
    // FIX: recover from half-connected state by retrying subscribe non-blocking.
    if (!gMqttSubscribed && nowMs >= gNextSubTryMs) {
      if (subscribeTopics()) {
        gMqttSubscribed = true;
        gMqttUp = true;
        gNeedSyncAfterReconnect = true;
        gFirstPacketReceived = false;
        gMqttSubRetryCount = 0;
        gMqttBackoffMs = MQTT_RETRY_BASE_MS;
        gNextSubTryMs = 0;
        Serial.println("MQTT resubscribed");
      } else {
        gMqttUp = false;
        gMqttSubRetryCount++;
        uint32_t subDelayMs = MQTT_SUB_RETRY_MS;
        if (gMqttSubRetryCount > MQTT_RETRY_LIMIT) {
          gMqttSubRetryCount = 0;
          gMqttBackoffMs = min(gMqttBackoffMs * 2U, MQTT_BACKOFF_CAP_MS);
          subDelayMs = gMqttBackoffMs;
        }
        gNextSubTryMs = nowMs + subDelayMs;
      }
      return;
    }
    gMqttUp = gMqttSubscribed;
    bool packetFresh = (nowMs - gLastRxMs) <= MQTT_SYNC_FRESH_MS;
    bool syncCompleted = (gMqttUp && gMqttSubscribed && gFirstPacketReceived && packetFresh);
    if (syncCompleted) {
      gNeedSyncAfterReconnect = false;
    }
    if (gMqttUp && !gNeedSyncAfterReconnect) {
      // FIX: full recovery reached (connected + subscribed) -> reset backoff/counters.
      gMqttBackoffMs = MQTT_RETRY_BASE_MS;
      gMqttRetryCount = 0;
      gMqttSubRetryCount = 0;
    }
    return;
  }

  if (nowMs < gNextMqttTryMs) return;

  const char* cid = buildClientId();
  if (gMqtt.connect(cid)) {
    gReconnectCount++;
    gNeedSyncAfterReconnect = true;
    gFirstPacketReceived = false;
    gMqttBackoffMs = MQTT_RETRY_BASE_MS;
    gMqttRetryCount = 0;
    gNextMqttTryMs = 0;
    gMqttSubscribed = false;
    gNextSubTryMs = 0;
    gMqttUp = false;
    Serial.print("MQTT TCP UP cid=");
    Serial.println(cid);
    return;
  }

  gMqttUp = false;
  gMqttSubscribed = false;
  gFirstPacketReceived = false;
  gMqttRetryCount++;
  if (gMqttRetryCount > MQTT_RETRY_LIMIT) {
    gMqttRetryCount = 0;
    gMqttBackoffMs = min(gMqttBackoffMs * 2U, MQTT_BACKOFF_CAP_MS);
  }
  gNextMqttTryMs = nowMs + gMqttBackoffMs;
  Serial.print("MQTT retry in ms=");
  Serial.print(gNextMqttTryMs - nowMs);
  Serial.print(" state=");
  Serial.println(gMqtt.state());
}

void processConnectivity(uint32_t nowMs) {
  gWifiManager.tick(nowMs);
  ensureMqtt(nowMs);

  if (gMqtt.connected()) {
    gMqtt.loop();
  }

  bool mqttConnected = gMqtt.connected();
  if (gPrevMqttConnected && !mqttConnected) {
    gMqttUp = false;
    gMqttSubscribed = false;
    gFirstPacketReceived = false;
    Serial.println("MQTT DOWN");
  }
  gPrevMqttConnected = mqttConnected;
}

void publishEspTelemetry(uint32_t nowMs) {
  if (!gMqtt.connected() || !gMqttUp) return;
  if ((nowMs - gLastTelemetryMs) < ESP_TELEMETRY_MS) return;
  gLastTelemetryMs = nowMs;

  // FIX #5: increase from 360 to 512 to prevent truncation on worst-case JSON.
  char payload[512];
  int n = snprintf(
      payload,
      sizeof(payload),
      "{\"ts_ms\":%lu,\"state\":\"%s\",\"confirmed\":\"%s\",\"driving\":%s,\"mqtt\":\"%s\",\"latency_total\":%lu,"
      "\"latency_avg\":%.2f,\"publish_to_esp\":%lu,\"esp_to_alert\":%lu,\"esp_receive_ts\":%lu,"
      "\"alert_trigger_ts\":%lu,\"packet_rate\":%.2f,\"packet_loss\":%lu,\"reconnects\":%lu}",
      static_cast<unsigned long>(nowMs),
      systemStateName(gStableState),
      systemStateName(gConfirmedState),
      gMotionDetector.isDriving() ? "true" : "false",
      gMqtt.connected() ? "UP" : "DOWN",
      static_cast<unsigned long>(gLastLatencyTotalMs),
      static_cast<double>(gLatencyAvgMs),
      static_cast<unsigned long>(gLastPublishToEspMs),
      static_cast<unsigned long>(gLastEspToAlertMs),
      static_cast<unsigned long>(gLastEspReceiveTsMs),
      static_cast<unsigned long>(gLastAlertEdgeMs),
      static_cast<double>(gPacketRateHz),
      static_cast<unsigned long>(gPacketLossCount),
      static_cast<unsigned long>(gReconnectCount));

  if (n > 0) {
    gMqtt.publish(MQTT_TOPIC_ESP_TELEMETRY, payload, false);
  }
}

// ============================================================
// Setup / Loop
// ============================================================
void setup() {
  Serial.begin(115200);

  pinMode(PIN_LED_GREEN, OUTPUT);
  pinMode(PIN_LED_RED, OUTPUT);
  pinMode(PIN_LED_BLUE, OUTPUT);
  pinMode(PIN_BUZZER, OUTPUT);
  pinMode(PIN_WIFI_RESET_BUTTON, INPUT_PULLUP);  // Method A: long-press WiFi reset

  if (USE_PASSIVE_SPEAKER) {
    ledcSetup(SPEAKER_LEDC_CH, SPEAKER_LEDC_BASE_FREQ, SPEAKER_LEDC_BITS);
    ledcAttachPin(PIN_SPEAKER, SPEAKER_LEDC_CH);
    ledcWriteTone(SPEAKER_LEDC_CH, 0);
  }

  setLeds(false, false, true);
  setAlarm(false, 0);

  gWifiManager.begin("DrowsySetup");
  Serial.println("[CFG] WiFi requireInternet=false healthHost=192.168.0.163:1883");
  Serial.println("[CFG] Motion threshold=0.08 persist=2000ms hold=2500ms");
  bool motionOk = gMotionDetector.begin();
  Serial.print("MPU6050 available=");
  Serial.println(motionOk ? "yes" : "no");

  gMqtt.setServer(MQTT_HOST, MQTT_PORT);
  gMqtt.setKeepAlive(10);
  gMqtt.setSocketTimeout(1);  // QW: reduced from 2s to 1s to halve reconnect stall
  gMqtt.setBufferSize(420);
  gMqtt.setCallback(onMqttMessage);

  uint32_t nowMs = millis();
  gLastRxMs = nowMs;
  gStableSinceMs = nowMs;
  gCandidateSinceMs = nowMs;
  gStartupStepUntilMs = nowMs;
  gLastStateChangeMs = nowMs - ALERT_STATE_DEBOUNCE_MS;
  gConfirmCandidate = gStableState;
  gConfirmCandidateSinceMs = nowMs;
  gConfirmedState = gStableState;
  gLastAlertState = gStableState;
  gFirstPacketReceived = false;
  gPacketRateMarkMs = nowMs;
}

void loop() {
  uint32_t nowMs = millis();

  gMotionDetector.tick(nowMs);
  checkWifiResetButton(nowMs);  // Method A: long-press button check
  processConnectivity(nowMs);

  // FIX #10: only update observation when driving state actually changes.
  // Previously this ran every ~1ms, continuously resetting gCandidateSinceMs
  // and preventing any pending state transition from persisting.
  if ((nowMs - gLastRxMs) <= gCurrentTtlMs && gRawAiState == AiState::SAFE) {
    SystemState idleState = gMotionDetector.isDriving() ? SystemState::DRIVING : SystemState::SAFE;
    if (idleState != gObservedState) {
      applyObservation(idleState, nowMs);
    }
  }

  applyDataWatchdog(nowMs);
  updateConfirmedState(nowMs);
  updateAlertEngine(nowMs);
  publishEspTelemetry(nowMs);

  if ((nowMs - gLastLogMs) >= LOG_GAP_MS) {
    gLastLogMs = nowMs;
    // QW1: consolidated from 35 Serial.print calls (~24ms) into single snprintf (~3ms)
    char logBuf[220];
    snprintf(logBuf, sizeof(logBuf),
      "W:%s P:%s M:%s AI:%s O:%s S:%s C:%s D:%s V:%.3f A:%d T:%lu R:%lu L:%lu Hz:%.1f X:%lu RC:%lu F:%d",
      gWifiManager.isConnected() ? "OK" : "DN",
      gWifiManager.portalActive() ? "ON" : "--",
      gMqtt.connected() ? "OK" : "DN",
      aiStateName(gRawAiState),
      systemStateName(gObservedState),
      systemStateName(gStableState),
      systemStateName(gConfirmedState),
      gMotionDetector.isDriving() ? "Y" : "N",
      static_cast<double>(gMotionDetector.vibrationLevel()),
      static_cast<int>(gAlertMode),
      static_cast<unsigned long>(gCurrentTtlMs),
      static_cast<unsigned long>(nowMs - gLastRxMs),
      static_cast<unsigned long>(gLastLatencyTotalMs),
      static_cast<double>(gPacketRateHz),
      static_cast<unsigned long>(gPacketLossCount),
      static_cast<unsigned long>(gReconnectCount),
      static_cast<int>(gWifiManager.flowState()));
    Serial.println(logBuf);
  }

  // No delay(): keep realtime responsiveness.
  yield();
}
