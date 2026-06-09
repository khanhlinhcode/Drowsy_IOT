#include <ArduinoJson.h>
#include <Preferences.h>
#include <PubSubClient.h>
#include <WiFi.h>
#include <ctype.h>
#include <string.h>

#include "motion_detector.h"
#include "oled_status.h"
#include "wifi_manager.h"

// Set to 1 for verbose per-message MQTT logging (adds ~8ms/msg).
// Keep 0 for production to minimize buzzer timing jitter.
#define VERBOSE 0

// ============================================================
// Configuration
// ============================================================
const char* MQTT_HOST_DEFAULT = "raspberrypi.local";
const uint16_t MQTT_PORT_DEFAULT = 1883;
const char* MQTT_CFG_NAMESPACE = "mqtt_cfg";
const size_t MQTT_HOST_MAX_LEN = 64;
const size_t SERIAL_LINE_MAX_LEN = 256;
const size_t IPV4_STR_MAX_LEN = 16;
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
const uint32_t PI_SYNC_AFTER_BROKER_GAP_MS = 2500;

// Data freshness / watchdog
const uint32_t DEFAULT_TTL_MS = 3000;
const uint32_t MIN_TTL_MS = 1200;
const uint32_t MAX_TTL_MS = 10000;

// State timing
const uint32_t STABLE_RISE_TIRED_MS = 220;
const uint32_t STABLE_RISE_SLEEPY_MS = 900;
const uint32_t STABLE_FALL_MS = 1100;
const uint32_t CONFIRMED_STATE_HOLD_MS = 180;
const uint32_t SLEEP_CONTINUOUS_MIN_MS = 0;  // Alert follows realtime state immediately.
// Hard timeout — force reset dangerous state when MQTT is dead for >30s.
const uint32_t WATCHDOG_HARD_TIMEOUT_MS = 30000;
const uint32_t DRIVING_CONFIRM_LOOK_STRAIGHT_MS = 5000;  // 5s face-forward to arm
// Short grace only for blink-level interruptions; prevents "early" 5s arm
// on repeated attempts after short look-away events.
const uint32_t DRIVING_CONFIRM_BREAK_GRACE_MS = 700;
const uint32_t DRIVING_CONFIRM_BREAK_RESET_MS = 12000;
const uint8_t DRIVING_ARM_MAX_FATIGUE = 50;               // FIX: 35→50 — allow arming with moderate fatigue
const uint32_t DRIVING_ARM_FATIGUE_GRACE_MS = 1200;       // FIX: 800→1200ms network jitter tolerance
// Fallback: if Pi keeps arm=0 while telemetry is healthy,
// switch quickly to local 5s gate so arming is not blocked indefinitely.
const uint32_t PI_ARM_FALSE_FALLBACK_MS = 2000;
const bool ENABLE_DRIVING_ARM_GATE = true;
const bool FOLLOW_PI_ARM_GATE = true;
// Boot UX option: startup beep when board powers up.
const bool ENABLE_STARTUP_BEEP_ON_BOOT = true;
// Extra cue for no-screen demo: beep twice when Pi+drowsy telemetry link is stable.
const bool ENABLE_PI_READY_BEEP = false;
const uint32_t PI_READY_BEEP_STABLE_MS = 1200;
// Demo UX (no-screen): beep "tip tip" when eyes/face are detected stably.
const uint32_t FACE_DETECT_BEEP_MIN_FACE_MS = 1200;
const uint8_t FACE_DETECT_BEEP_MIN_PACKET_COUNT = 4;
const uint32_t FACE_DETECT_BEEP_NOFACE_REARM_MS = 4000;
const uint32_t FACE_DETECT_BEEP_COOLDOWN_MS = 8000;
const bool FACE_DETECT_BEEP_ONCE_PER_BOOT = false;
const uint32_t ESP_TELEMETRY_MS = 1000;
const char* MQTT_TOPIC_ESP_TELEMETRY = "driver/esp32_telemetry";
const uint32_t SLEEP_ALARM_MAX_MS = 5000;
const uint32_t OLED_DROWSY_ALERT_HOLD_MS = 3000;
const uint32_t OLED_REST_WARNING_HOLD_MS = 10000;
const uint32_t OLED_DROWSY_REPEAT_WINDOW_MS = 60000;

const uint32_t LOG_GAP_MS = 1500;

WiFiClient gWifi;
PubSubClient gMqtt(gWifi);
WifiManager gWifiManager;
MotionDetector gMotionDetector;
OledStatusDisplay gOledStatus;
Preferences gMqttPrefs;
bool gMqttPrefsReady = false;
char gMqttHost[MQTT_HOST_MAX_LEN] = {0};
uint16_t gMqttPort = MQTT_PORT_DEFAULT;
char gSerialLineBuf[SERIAL_LINE_MAX_LEN] = {0};
size_t gSerialLineLen = 0;

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
  bool hasNoFace = false;
  bool noFace = false;
  bool hasFaceLock = false;
  bool faceLock = false;
  bool hasArmed = false;
  bool armed = true;
  bool hasArmProgressPct = false;
  uint8_t armProgressPct = 0;
  bool hasArmRemainingMs = false;
  uint32_t armRemainingMs = 0;
  bool hasPiIp = false;
  char piIp[IPV4_STR_MAX_LEN] = {0};
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
int gRawFatigue = 0;
bool gRawNoFace = false;
bool gRawFaceLock = false;
bool gPiArmed = false;
bool gPiArmedKnown = false;
bool gPiArmedRisePending = false;
bool gPiArmProgressKnown = false;
uint8_t gPiArmProgressPct = 0;
bool gPiArmRemainingKnown = false;
uint32_t gPiArmRemainingMs = 0;
bool gPiIpKnown = false;
char gPiIp[IPV4_STR_MAX_LEN] = {0};
bool gPiArmFallbackActive = false;
uint32_t gPiArmFalseSinceMs = 0;
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
bool gMqttTcpConnected = false;
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
bool gStartupActive = ENABLE_STARTUP_BEEP_ON_BOOT;
uint8_t gStartupStep = 0;
uint32_t gStartupStepUntilMs = 0;
bool gPiReadyBeepActive = false;
bool gPiReadyBeepDoneBoot = false;
uint8_t gPiReadyBeepStep = 0;
uint32_t gPiReadyBeepUntilMs = 0;
uint32_t gPiReadySinceMs = 0;
bool gDrivingConfirmBeepActive = false;
uint8_t gDrivingConfirmStep = 0;
uint32_t gDrivingConfirmStepUntilMs = 0;
bool gFaceDetectedBeepActive = false;
uint8_t gFaceDetectedBeepStep = 0;
uint32_t gFaceDetectedBeepUntilMs = 0;
bool gFaceDetectBeepArmed = true;
bool gFaceDetectBeepDoneBoot = false;
uint32_t gFaceDetectFlashUntilMs = 0;
uint32_t gFaceVisibleSinceMs = 0;
uint32_t gFaceVisibleLastRxMs = 0;
uint16_t gFaceVisiblePacketCount = 0;
uint32_t gNoFaceSinceMs = 0;
uint32_t gLastFaceDetectBeepMs = 0;
bool gDrowsyDetectionArmed = !ENABLE_DRIVING_ARM_GATE;
uint32_t gAttentiveSinceMs = 0;
uint32_t gLastArmProgressLogMs = 0;
uint32_t gAttentiveBreakSinceMs = 0;
uint32_t gAttentivePauseAccumMs = 0;
uint32_t gArmNotAttentiveSinceMs = 0;
uint32_t gArmHighFatigueSinceMs = 0;

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
uint32_t gLastPiBrokerSyncMs = 0;
uint32_t gAlarmModeStartMs = 0;
bool gSleepAlarmCutoffActive = false;

uint32_t gLastLogMs = 0;
uint32_t gLastMqttRetryLogMs = 0;
bool gMetaSessionRestartPending = false;
bool gOledDrowsyAlertActive = false;
bool gOledRestWarningActive = false;
bool gOledDangerPrev = false;
uint32_t gOledLastDrowsyEventMs = 0;
uint32_t gOledPrevDrowsyEventMs = 0;
uint32_t gOledDrowsyAlertSinceMs = 0;
uint32_t gOledRestWarningSinceMs = 0;

// ============================================================
// Utility
// ============================================================
int stateLevel(SystemState s) { return static_cast<int>(s); }

bool isDangerous(SystemState s) { return stateLevel(s) >= stateLevel(SystemState::SLEEPY); }

bool isDrivingActive() {
  if (!gMotionDetector.available()) {
    return true;
  }
  if (gMotionDetector.isDriving()) {
    return true;
  }
  // Demo-safe fallback: if Pi stream is fresh, do not hard-block alerts
  // because of temporary motion sensor under-detection.
  const uint32_t nowMs = millis();
  const uint32_t ageMs = (nowMs >= gLastRxMs) ? (nowMs - gLastRxMs) : 0;
  const uint32_t freshMs = max(gCurrentTtlMs, static_cast<uint32_t>(6000));
  return gMqttUp && gFirstPacketReceived && (ageMs <= freshMs);
}

void resetDrivingArmGateState(uint32_t nowMs, const char* reason) {
  if (!ENABLE_DRIVING_ARM_GATE) return;
  gDrowsyDetectionArmed = false;
  gDrivingConfirmBeepActive = false;
  gDrivingConfirmStep = 0;
  gDrivingConfirmStepUntilMs = nowMs;
  gAttentiveSinceMs = 0;
  gAttentiveBreakSinceMs = 0;
  gAttentivePauseAccumMs = 0;
  gLastArmProgressLogMs = 0;
  gArmNotAttentiveSinceMs = 0;
  gArmHighFatigueSinceMs = 0;
  gPiArmedRisePending = false;
  gPiArmFallbackActive = false;
  gPiArmFalseSinceMs = 0;
  Serial.print("[DRIVE] disarmed: ");
  Serial.println(reason == nullptr ? "unknown" : reason);
}

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

const char* alertModeName(AlertMode m) {
  switch (m) {
    case AlertMode::OFF:
      return "OFF";
    case AlertMode::DRIVING_DOUBLE_BEEP:
      return "DRIVE2";
    case AlertMode::TIRED_SLOW_BEEP:
      return "SLOW";
    case AlertMode::SLEEPY_FAST_BEEP:
      return "FAST";
    case AlertMode::SLEEP_CONTINUOUS:
      return "CONT";
  }
  return "OFF";
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

// FIX: guard unsigned time deltas against same-loop timestamp reordering.
uint32_t safeElapsedMs(uint32_t nowMs, uint32_t pastMs) {
  return (nowMs >= pastMs) ? (nowMs - pastMs) : 0;
}

uint8_t clampPercent(int value) {
  if (value <= 0) return 0;
  if (value >= 100) return 100;
  return static_cast<uint8_t>(value);
}

void updateOledStatus(uint32_t nowMs) {
  (void)nowMs;
  OledStatusSnapshot snapshot;
  snapshot.wifiConnected = gWifiManager.isConnected();
  snapshot.mqttReady = gMqttTcpConnected && gMqttUp;
  snapshot.piLinkReady = snapshot.wifiConnected && snapshot.mqttReady && gFirstPacketReceived;
  if (snapshot.wifiConnected) {
    IPAddress espIp = gWifiManager.localIP();
    const bool validEspIp = (espIp[0] != 0 || espIp[1] != 0 || espIp[2] != 0 || espIp[3] != 0);
    if (validEspIp) {
      snprintf(
          snapshot.espIp,
          sizeof(snapshot.espIp),
          "%u.%u.%u.%u",
          static_cast<unsigned>(espIp[0]),
          static_cast<unsigned>(espIp[1]),
          static_cast<unsigned>(espIp[2]),
          static_cast<unsigned>(espIp[3]));
      snapshot.espIpKnown = true;
    }
  }
  snapshot.piIpKnown = gPiIpKnown && (gPiIp[0] != '\0');
  if (snapshot.piIpKnown) {
    strncpy(snapshot.piIp, gPiIp, sizeof(snapshot.piIp) - 1);
    snapshot.piIp[sizeof(snapshot.piIp) - 1] = '\0';
  }
  snapshot.faceLocked = (!gRawNoFace) && gRawFaceLock;
  snapshot.armed = ENABLE_DRIVING_ARM_GATE ? gDrowsyDetectionArmed : true;
  snapshot.drowsyAlert = gOledDrowsyAlertActive;
  snapshot.restWarning = gOledRestWarningActive;

  if (!snapshot.piLinkReady) {
    snapshot.progressPct = 0;
  } else if (snapshot.armed) {
    snapshot.progressPct = 100;
  } else if (gPiArmProgressKnown) {
    snapshot.progressFromPi = true;
    snapshot.progressPct = gPiArmProgressPct;
  } else {
    snapshot.progressPct = 0;
  }

  gOledStatus.update(nowMs, snapshot);
}

void updateOledWarnings(uint32_t nowMs) {
  const bool streamFresh = gFirstPacketReceived && (safeElapsedMs(nowMs, gLastRxMs) <= gCurrentTtlMs);
  if (!streamFresh) {
    gOledDrowsyAlertActive = false;
    gOledRestWarningActive = false;
    gOledDangerPrev = false;
    gOledDrowsyAlertSinceMs = 0;
    gOledRestWarningSinceMs = 0;
    return;
  }

  const bool dangerNow = isDangerous(gConfirmedState);
  if (dangerNow && !gOledDangerPrev) {
    gOledDrowsyAlertSinceMs = nowMs;
    gOledPrevDrowsyEventMs = gOledLastDrowsyEventMs;
    gOledLastDrowsyEventMs = nowMs;
    if (gOledPrevDrowsyEventMs > 0 &&
        safeElapsedMs(nowMs, gOledPrevDrowsyEventMs) <= OLED_DROWSY_REPEAT_WINDOW_MS) {
      gOledRestWarningSinceMs = nowMs;
      Serial.println("[OLED] repeated drowsy in 60s -> rest warning");
    }
  }
  gOledDangerPrev = dangerNow;

  bool holdDrowsy = false;
  if (gOledDrowsyAlertSinceMs > 0) {
    holdDrowsy = safeElapsedMs(nowMs, gOledDrowsyAlertSinceMs) < OLED_DROWSY_ALERT_HOLD_MS;
    if (!holdDrowsy) gOledDrowsyAlertSinceMs = 0;
  }

  bool holdRest = false;
  if (gOledRestWarningSinceMs > 0) {
    holdRest = safeElapsedMs(nowMs, gOledRestWarningSinceMs) < OLED_REST_WARNING_HOLD_MS;
    if (!holdRest) gOledRestWarningSinceMs = 0;
  }

  gOledDrowsyAlertActive = dangerNow || holdDrowsy;
  gOledRestWarningActive = holdRest;
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

bool setMqttHostSafe(const char* host) {
  if (host == nullptr) return false;
  size_t n = strlen(host);
  if (n == 0 || n >= MQTT_HOST_MAX_LEN) return false;
  memcpy(gMqttHost, host, n);
  gMqttHost[n] = '\0';
  return true;
}

void resetMqttSessionState() {
  if (gMqttTcpConnected) {
    gMqtt.disconnect();
  }
  gMqttTcpConnected = false;
  gMqttUp = false;
  gMqttSubscribed = false;
  gFirstPacketReceived = false;
  gNeedSyncAfterReconnect = true;
  gMqttRetryCount = 0;
  gMqttSubRetryCount = 0;
  gMqttBackoffMs = MQTT_RETRY_BASE_MS;
  gNextMqttTryMs = 0;
  gNextSubTryMs = 0;
  gPiArmProgressKnown = false;
  gPiArmRemainingKnown = false;
  gPiIpKnown = false;
  gPiIp[0] = '\0';
}

void applyMqttBroker(const char* host, uint16_t port, bool persist, const char* sourceTag) {
  if (host == nullptr || host[0] == '\0') return;
  if (port == 0) port = MQTT_PORT_DEFAULT;

  const bool changed = (strcmp(gMqttHost, host) != 0) || (gMqttPort != port);
  if (!setMqttHostSafe(host)) return;
  gMqttPort = port;
  gMqtt.setServer(gMqttHost, gMqttPort);

  if (persist && gMqttPrefsReady) {
    gMqttPrefs.putString("host", gMqttHost);
    gMqttPrefs.putUShort("port", gMqttPort);
  }

  if (changed) {
    resetMqttSessionState();
    Serial.print("[MQTT] broker=");
    Serial.print(gMqttHost);
    Serial.print(":");
    Serial.print(gMqttPort);
    Serial.print(" src=");
    Serial.println(sourceTag == nullptr ? "unknown" : sourceTag);
  }
}

void loadMqttBrokerConfig() {
  setMqttHostSafe(MQTT_HOST_DEFAULT);
  gMqttPort = MQTT_PORT_DEFAULT;

  if (gMqttPrefs.begin(MQTT_CFG_NAMESPACE, false)) {
    gMqttPrefsReady = true;
    String host = gMqttPrefs.getString("host", MQTT_HOST_DEFAULT);
    uint16_t port = gMqttPrefs.getUShort("port", MQTT_PORT_DEFAULT);
    if (host.length() > 0 && host.length() < MQTT_HOST_MAX_LEN) {
      setMqttHostSafe(host.c_str());
    }
    if (port > 0) {
      gMqttPort = port;
    }
  }

  gMqtt.setServer(gMqttHost, gMqttPort);
}

void handlePiBrokerLine(const char* line) {
  if (line == nullptr || line[0] == '\0') return;

  const bool isSyncReqLine = (strncmp(line, "[PI_SYNC_REQ]", 13) == 0);
  if (isSyncReqLine) {
    gWifiManager.notifyPiBridgeSeen(millis());
    gWifiManager.requestPiSync(millis());
    return;
  }

  const char* payload = line;
  if (strncmp(line, "[PI_BROKER]", 11) == 0) {
    payload = line + 11;
    while (*payload == ' ' || *payload == ':') payload++;
  } else if (line[0] != '{') {
    return;
  }

  JsonDocument doc;
  DeserializationError err = deserializeJson(doc, payload);
  if (err) return;

  const char* type = doc["type"].as<const char*>();
  if (equalsIgnoreCase(type, "pi_sync_request") || equalsIgnoreCase(type, "wifi_sync_request")) {
    gWifiManager.notifyPiBridgeSeen(millis());
    gWifiManager.requestPiSync(millis());
    return;
  }

  const bool looksLikeBroker = (strncmp(line, "[PI_BROKER]", 11) == 0) ||
                               equalsIgnoreCase(type, "broker") ||
                               equalsIgnoreCase(type, "mqtt_broker");
  if (!looksLikeBroker) return;

  gWifiManager.notifyPiBridgeSeen(millis());

  const char* host = doc["host"].as<const char*>();
  uint16_t port = doc["port"].is<uint16_t>() ? doc["port"].as<uint16_t>() : MQTT_PORT_DEFAULT;
  applyMqttBroker(host, port, true, "serial");
  uint32_t nowMs = millis();
  if ((nowMs - gLastPiBrokerSyncMs) >= PI_SYNC_AFTER_BROKER_GAP_MS) {
    gWifiManager.requestPiSync(nowMs);
    gLastPiBrokerSyncMs = nowMs;
  }
}

void pollSerialControl() {
  while (Serial.available() > 0) {
    char c = static_cast<char>(Serial.read());
    if (c == '\r') continue;

    if (c == '\n') {
      gSerialLineBuf[gSerialLineLen] = '\0';
      if (gSerialLineLen > 0) {
        handlePiBrokerLine(gSerialLineBuf);
      }
      gSerialLineLen = 0;
      continue;
    }

    if (gSerialLineLen < (SERIAL_LINE_MAX_LEN - 1)) {
      gSerialLineBuf[gSerialLineLen++] = c;
    } else {
      gSerialLineLen = 0;
    }
  }
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

  if (equalsIgnoreCase(statusText, "DROWSY")) {
    return AiState::SLEEP;
  }
  if (equalsIgnoreCase(statusText, "MICROSLEEP") || equalsIgnoreCase(statusText, "SLEEP")) {
    return AiState::SLEEP;
  }
  if (equalsIgnoreCase(statusText, "SLEEPY") ||
      equalsIgnoreCase(statusText, "VERY TIRED") ||
      equalsIgnoreCase(statusText, "HEAD DOWN") ||
      equalsIgnoreCase(statusText, "DISTRACTED") ||
      equalsIgnoreCase(statusText, "LOOKING DOWN")) {
    return AiState::SLEEPY;
  }
  if (equalsIgnoreCase(statusText, "TIRED") ||
      equalsIgnoreCase(statusText, "LOOKING LEFT") ||
      equalsIgnoreCase(statusText, "LOOKING RIGHT") ||
      equalsIgnoreCase(statusText, "LOOKING SIDE") ||
      equalsIgnoreCase(statusText, "HEAD TILT")) {
    return AiState::TIRED;
  }
  if (equalsIgnoreCase(statusText, "ATTENTIVE") ||
      equalsIgnoreCase(statusText, "AWAKE") ||
      equalsIgnoreCase(statusText, "NORMAL") ||
      equalsIgnoreCase(statusText, "NO FACE") ||
      equalsIgnoreCase(statusText, "NO_FACE")) {
    return AiState::SAFE;
  }

  if (ok != nullptr) *ok = false;
  return AiState::SAFE;
}

SystemState deriveObservedState(AiState aiState, bool driving, bool detectionArmed, bool noFace) {
  if (noFace) return SystemState::SAFE;
  // CRITICAL: microsleep/sleep must alarm immediately, never blocked by arm gate.
  if (aiState == AiState::SLEEP) return SystemState::SLEEP;
  if (!driving) return SystemState::SAFE;
  if (ENABLE_DRIVING_ARM_GATE && !detectionArmed) return SystemState::SAFE;

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

void runTripleBeepPattern(uint32_t nowMs, uint16_t toneHz) {
  if (nowMs < gPatternUntilMs) return;

  switch (gPatternStep) {
    case 0:
      setAlarm(true, toneHz);
      gPatternUntilMs = nowMs + 100;
      gPatternStep = 1;
      break;
    case 1:
      setAlarm(false, 0);
      gPatternUntilMs = nowMs + 110;
      gPatternStep = 2;
      break;
    case 2:
      setAlarm(true, toneHz);
      gPatternUntilMs = nowMs + 100;
      gPatternStep = 3;
      break;
    case 3:
      setAlarm(false, 0);
      gPatternUntilMs = nowMs + 110;
      gPatternStep = 4;
      break;
    case 4:
      setAlarm(true, toneHz);
      gPatternUntilMs = nowMs + 100;
      gPatternStep = 5;
      break;
    default:
      setAlarm(false, 0);
      gPatternUntilMs = nowMs + 650;
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
      // CRITICAL: hold final silence so startup sequence is ~1 second total.
      setAlarm(false, 0);
      gStartupStepUntilMs = nowMs + 660;
      gStartupStep = 4;
      return true;
    default:
      setAlarm(false, 0);
      setLeds(true, false, false);
      gStartupActive = false;
      return false;
  }
}

bool runPiReadyBeepSequence(uint32_t nowMs) {
  if (!gPiReadyBeepActive) return false;
  if (isDangerous(gStableState)) {
    gPiReadyBeepActive = false;
    setAlarm(false, 0);
    return false;
  }
  if (nowMs < gPiReadyBeepUntilMs) return true;

  switch (gPiReadyBeepStep) {
    case 0:
      setAlarm(true, 2200);
      gPiReadyBeepUntilMs = nowMs + 90;
      gPiReadyBeepStep = 1;
      return true;
    case 1:
      setAlarm(false, 0);
      gPiReadyBeepUntilMs = nowMs + 100;
      gPiReadyBeepStep = 2;
      return true;
    case 2:
      setAlarm(true, 2200);
      gPiReadyBeepUntilMs = nowMs + 90;
      gPiReadyBeepStep = 3;
      return true;
    default:
      setAlarm(false, 0);
      gPiReadyBeepActive = false;
      gPiReadyBeepStep = 0;
      gPiReadyBeepUntilMs = nowMs;
      return false;
  }
}

bool runDrivingConfirmSequence(uint32_t nowMs) {
  if (!gDrivingConfirmBeepActive) return false;
  if (isDangerous(gStableState)) {
    gDrivingConfirmBeepActive = false;
    setAlarm(false, 0);
    return false;
  }
  if (nowMs < gDrivingConfirmStepUntilMs) return true;

  switch (gDrivingConfirmStep) {
    case 0:
      setAlarm(true, 2300);
      gDrivingConfirmStepUntilMs = nowMs + 130;
      gDrivingConfirmStep = 1;
      return true;
    case 1:
      setAlarm(false, 0);
      gDrivingConfirmStepUntilMs = nowMs + 110;
      gDrivingConfirmStep = 2;
      return true;
    case 2:
      setAlarm(true, 2300);
      gDrivingConfirmStepUntilMs = nowMs + 130;
      gDrivingConfirmStep = 3;
      return true;
    case 3:
      setAlarm(false, 0);
      gDrivingConfirmStepUntilMs = nowMs + 110;
      gDrivingConfirmStep = 4;
      return true;
    case 4:
      setAlarm(true, 2300);
      gDrivingConfirmStepUntilMs = nowMs + 130;
      gDrivingConfirmStep = 5;
      return true;
    default:
      setAlarm(false, 0);
      gDrivingConfirmBeepActive = false;
      gDrivingConfirmStep = 0;
      gDrivingConfirmStepUntilMs = nowMs;
      return false;
  }
}

bool runFaceDetectedBeepSequence(uint32_t nowMs) {
  if (!gFaceDetectedBeepActive) return false;
  if (isDangerous(gStableState)) {
    gFaceDetectedBeepActive = false;
    setAlarm(false, 0);
    return false;
  }
  if (nowMs < gFaceDetectedBeepUntilMs) return true;

  switch (gFaceDetectedBeepStep) {
    case 0:
      setAlarm(true, 2200);
      gFaceDetectedBeepUntilMs = nowMs + 90;
      gFaceDetectedBeepStep = 1;
      return true;
    case 1:
      setAlarm(false, 0);
      gFaceDetectedBeepUntilMs = nowMs + 50;
      gFaceDetectedBeepStep = 2;
      return true;
    default:
      setAlarm(false, 0);
      gFaceDetectedBeepActive = false;
      gFaceDetectedBeepStep = 0;
      gFaceDetectedBeepUntilMs = nowMs;
      return false;
  }
}

void updatePiReadyBeepTrigger(uint32_t nowMs) {
  if (!ENABLE_PI_READY_BEEP || gPiReadyBeepDoneBoot || gPiReadyBeepActive) return;
  if (gStartupActive || gDrivingConfirmBeepActive || isDangerous(gStableState)) return;

  const bool commReady = gWifiManager.isConnected() && gMqttTcpConnected && gMqttUp;
  if (!commReady || !gFirstPacketReceived) {
    gPiReadySinceMs = 0;
    return;
  }

  const uint32_t freshnessMs = max(gCurrentTtlMs, static_cast<uint32_t>(1200));
  const bool telemetryFresh = (safeElapsedMs(nowMs, gLastRxMs) <= freshnessMs);
  if (!telemetryFresh) {
    gPiReadySinceMs = 0;
    return;
  }

  if (gPiReadySinceMs == 0) {
    gPiReadySinceMs = nowMs;
    return;
  }
  if (safeElapsedMs(nowMs, gPiReadySinceMs) < PI_READY_BEEP_STABLE_MS) return;

  gPiReadyBeepDoneBoot = true;
  gPiReadyBeepActive = true;
  gPiReadyBeepStep = 0;
  gPiReadyBeepUntilMs = nowMs;
  Serial.println("[READY] Pi+drowsy telemetry stable -> ready beep (2 beeps)");
}

void updateFaceDetectedBeepTrigger(uint32_t nowMs) {
  if (FACE_DETECT_BEEP_ONCE_PER_BOOT && gFaceDetectBeepDoneBoot) return;

  const bool commReady = gWifiManager.isConnected() && gMqttTcpConnected && gMqttUp;
  if (!commReady) {
    gFaceVisibleSinceMs = 0;
    gFaceVisibleLastRxMs = 0;
    gFaceVisiblePacketCount = 0;
    return;
  }

  const uint32_t freshnessMs = max(gCurrentTtlMs, static_cast<uint32_t>(1200));
  const bool telemetryFresh = gFirstPacketReceived && (safeElapsedMs(nowMs, gLastRxMs) <= freshnessMs);
  const bool faceVisible =
      telemetryFresh &&
      (!gRawNoFace) &&
      (gRawAiState == AiState::SAFE) &&
      gRawFaceLock;

  if (!faceVisible) {
    gFaceVisibleSinceMs = 0;
    gFaceVisibleLastRxMs = 0;
    gFaceVisiblePacketCount = 0;
    if (gNoFaceSinceMs == 0) gNoFaceSinceMs = nowMs;
    if (!gFaceDetectBeepArmed &&
        safeElapsedMs(nowMs, gNoFaceSinceMs) >= FACE_DETECT_BEEP_NOFACE_REARM_MS) {
      gFaceDetectBeepArmed = true;
    }
    return;
  }

  gNoFaceSinceMs = 0;
  if (gFaceVisibleSinceMs == 0) {
    gFaceVisibleSinceMs = nowMs;
    gFaceVisibleLastRxMs = gLastRxMs;
    gFaceVisiblePacketCount = 1;
    return;
  }
  if (gLastRxMs != gFaceVisibleLastRxMs) {
    gFaceVisibleLastRxMs = gLastRxMs;
    if (gFaceVisiblePacketCount < 0xFFFFu) gFaceVisiblePacketCount++;
  }

  if (!gFaceDetectBeepArmed || gFaceDetectedBeepActive) return;
  if (safeElapsedMs(nowMs, gFaceVisibleSinceMs) < FACE_DETECT_BEEP_MIN_FACE_MS) return;
  if (gFaceVisiblePacketCount < FACE_DETECT_BEEP_MIN_PACKET_COUNT) return;
  if (safeElapsedMs(nowMs, gLastFaceDetectBeepMs) < FACE_DETECT_BEEP_COOLDOWN_MS) return;
  if (gStartupActive || gPiReadyBeepActive || gDrivingConfirmBeepActive || isDangerous(gStableState)) return;

  gFaceDetectBeepArmed = false;
  gFaceDetectBeepDoneBoot = true;
  gLastFaceDetectBeepMs = nowMs;
  gFaceDetectedBeepActive = true;
  gFaceDetectedBeepStep = 0;
  gFaceDetectedBeepUntilMs = nowMs;
  gFaceDetectFlashUntilMs = nowMs + 240;
  Serial.printf(
      "[FACE] eyes detected -> confirm beep (1 beep) + red flash (packets=%u, hold=%lums)\n",
      static_cast<unsigned int>(gFaceVisiblePacketCount),
      static_cast<unsigned long>(safeElapsedMs(nowMs, gFaceVisibleSinceMs)));
}

bool isAttentiveForDrivingArm(uint32_t nowMs);

void resetFaceDetectCueGate(uint32_t nowMs, const char* reason) {
  gFaceDetectBeepArmed = true;
  gFaceDetectBeepDoneBoot = false;
  gFaceVisibleSinceMs = 0;
  gFaceVisibleLastRxMs = 0;
  gFaceVisiblePacketCount = 0;
  gNoFaceSinceMs = nowMs;
  if (reason != nullptr && reason[0] != '\0') {
    Serial.print("[FACE] cue rearmed: ");
    Serial.println(reason);
  }
}

void updateDrivingArmGate(uint32_t nowMs) {
  if (!ENABLE_DRIVING_ARM_GATE) {
    gDrowsyDetectionArmed = true;
    return;
  }
  // Follow Pi arm gate when Pi provides "armed" metadata.
  // This guarantees arm timing comes from Pi's forward-face 5s logic only.
  if (FOLLOW_PI_ARM_GATE && gPiArmedKnown) {
    // Pi arm gate: source-of-truth.
    const uint32_t armFreshMs = max(gCurrentTtlMs, static_cast<uint32_t>(6000));
    const bool piMetaFresh = gMqttUp && gFirstPacketReceived &&
                             (safeElapsedMs(nowMs, gLastRxMs) <= armFreshMs);
    if (!piMetaFresh) {
      gPiArmFallbackActive = false;
      gPiArmFalseSinceMs = 0;
      if (gDrowsyDetectionArmed) {
        resetDrivingArmGateState(nowMs, "pi_meta_stale");
      }
      return;
    }
    if (!gPiArmed) {
      // Pi explicitly says gate is OFF -> keep disarmed, no local fallback.
      gPiArmFalseSinceMs = nowMs;
      gPiArmFallbackActive = false;
      if (gDrowsyDetectionArmed) {
        resetDrivingArmGateState(nowMs, "pi_gate_off");
      }
      return;
    } else {
      gPiArmFalseSinceMs = 0;
      gPiArmFallbackActive = false;
      if (gDrowsyDetectionArmed) {
        // Already armed and Pi still armed -> keep armed.
      } else {
        gDrowsyDetectionArmed = true;
        if (!isDangerous(gStableState)) {
          gDrivingConfirmBeepActive = true;
          gDrivingConfirmStep = 0;
          gDrivingConfirmStepUntilMs = nowMs;
          if (gPiArmedRisePending) {
            Serial.println("[DRIVE] Pi armed rise -> confirm beep (3 beeps)");
          } else {
            Serial.println("[DRIVE] Pi armed sync -> confirm beep (3 beeps)");
          }
        } else {
          Serial.println("[DRIVE] Pi armed -> detection enabled (silent)");
        }
        gPiArmedRisePending = false;
      }
      return;
    }
  }

  if (gDrowsyDetectionArmed) return;
  const bool attentiveNow = isAttentiveForDrivingArm(nowMs);
  if (!attentiveNow) {
    if (gAttentiveSinceMs != 0) {
      if (gAttentiveBreakSinceMs == 0) {
        gAttentiveBreakSinceMs = nowMs;
        Serial.println("[DRIVE] attentive pause");
        return;
      }
      if (safeElapsedMs(nowMs, gAttentiveBreakSinceMs) < DRIVING_CONFIRM_BREAK_RESET_MS) {
        return;
      }
      Serial.println("[DRIVE] attentive window reset");
    }
    gAttentiveSinceMs = 0;
    gAttentiveBreakSinceMs = 0;
    gAttentivePauseAccumMs = 0;
    gLastArmProgressLogMs = 0;
    return;
  }

  if (gAttentiveSinceMs == 0) {
    gAttentiveSinceMs = nowMs;
    gAttentivePauseAccumMs = 0;
    gAttentiveBreakSinceMs = 0;
    gLastArmProgressLogMs = nowMs;
    Serial.println("[DRIVE] attentive window start (need 5s)");
    return;
  }

  if (gAttentiveBreakSinceMs != 0) {
    const uint32_t breakMs = safeElapsedMs(nowMs, gAttentiveBreakSinceMs);
    if (breakMs > DRIVING_CONFIRM_BREAK_GRACE_MS) {
      const uint32_t penalty = breakMs - DRIVING_CONFIRM_BREAK_GRACE_MS;
      const uint32_t maxPenalty = DRIVING_CONFIRM_LOOK_STRAIGHT_MS * 2U;
      gAttentivePauseAccumMs = min(gAttentivePauseAccumMs + penalty, maxPenalty);
    }
    gAttentiveBreakSinceMs = 0;
  }

  const uint32_t elapsedMs = safeElapsedMs(nowMs, gAttentiveSinceMs);
  const uint32_t effectiveMs = (elapsedMs > gAttentivePauseAccumMs) ? (elapsedMs - gAttentivePauseAccumMs) : 0;

  if ((nowMs - gLastArmProgressLogMs) >= 5000) {
    uint32_t elapsedSec = effectiveMs / 1000;
    Serial.print("[DRIVE] attentive progress ");
    Serial.print(elapsedSec);
    Serial.println("s/5s");
    gLastArmProgressLogMs = nowMs;
  }

  if (effectiveMs < DRIVING_CONFIRM_LOOK_STRAIGHT_MS) return;

  gDrowsyDetectionArmed = true;
  gDrivingConfirmBeepActive = true;
  gDrivingConfirmStep = 0;
  gDrivingConfirmStepUntilMs = nowMs;
  gAttentiveSinceMs = nowMs;
  gAttentivePauseAccumMs = 0;
  gAttentiveBreakSinceMs = 0;
  gLastArmProgressLogMs = 0;
  Serial.println("[DRIVE] attentive 5s confirmed -> drowsy detection armed");
}

bool isAttentiveForDrivingArm(uint32_t nowMs) {
  if (!ENABLE_DRIVING_ARM_GATE) {
    return (safeElapsedMs(nowMs, gLastRxMs) <= gCurrentTtlMs) && isDrivingActive();
  }
  if (gStartupActive) return false;

  // When Pi arm gate is active and known, the Pi branch in updateDrivingArmGate()
  // handles everything — the local 5s gate is not used in parallel.
  if (FOLLOW_PI_ARM_GATE && gPiArmedKnown && !gPiArmFallbackActive) {
    return false;  // Pi branch handles this; local gate must NOT run simultaneously.
  }

  // LOCAL 5s GATE — used in two cases:
  //   1. Pi never connected (true standalone mode).
  //   2. Pi connected but never sent armed metadata (old Pi firmware).
  const bool hasMqttData = gMqttUp && gFirstPacketReceived &&
                           (safeElapsedMs(nowMs, gLastRxMs) <= gCurrentTtlMs);
  const bool noPiEver = !gPiArmedKnown && !gFirstPacketReceived;

  if (!hasMqttData && !noPiEver) {
    // Had Pi data at some point but now stale — do not arm with stale data.
    return false;
  }

  if (hasMqttData) {
    if (gRawNoFace) {
      return false;
    }
    const bool aiAttentiveEnough = (gRawAiState == AiState::SAFE);
    if (!aiAttentiveEnough) {
      if (gArmNotAttentiveSinceMs == 0) gArmNotAttentiveSinceMs = nowMs;
      if (safeElapsedMs(nowMs, gArmNotAttentiveSinceMs) > 1500) return false;
    } else {
      gArmNotAttentiveSinceMs = 0;
    }
    const bool fatigueTooHigh = (gRawFatigue > static_cast<int>(DRIVING_ARM_MAX_FATIGUE));
    if (fatigueTooHigh) {
      if (gArmHighFatigueSinceMs == 0) gArmHighFatigueSinceMs = nowMs;
      if (safeElapsedMs(nowMs, gArmHighFatigueSinceMs) > DRIVING_ARM_FATIGUE_GRACE_MS) return false;
    } else {
      gArmHighFatigueSinceMs = 0;
    }
    // When camera telemetry is healthy and attentive enough,
    // allow arm without requiring motion sensor vibration.
    return true;
  }

  // Standalone fallback (no Pi data ever): keep conservative motion requirement.
  return noPiEver && isDrivingActive();
}

AlertMode resolveAlertMode(uint32_t nowMs) {

  const SystemState alertState = gLastAlertState;
  // CRITICAL: no hold lock after leaving SLEEP; follow realtime state.
  (void)nowMs;
  if (alertState == SystemState::SLEEP) {
    return AlertMode::SLEEP_CONTINUOUS;
  }

  // Suppress DRIVING double-beep only when telemetry is down (TIRED/SLEEPY are safety-critical).
  if (!gWifiManager.isConnected() || !gMqttUp) {
    if (alertState == SystemState::DRIVING) {
      return AlertMode::OFF;
    }
  }

  switch (alertState) {
    case SystemState::SAFE:
      return AlertMode::OFF;
    case SystemState::DRIVING:
      return AlertMode::OFF;
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
      // Make armed-driving visually distinct from SAFE.
      setLeds(true, false, true);
      break;
    case SystemState::TIRED:
      setLeds(true, true, false);
      break;
    case SystemState::SLEEPY:
      // Keep RED solid for drowsy so warning is visible even if buzzer is
      // temporarily suppressed by connectivity/gating conditions.
      setLeds(false, true, false);
      break;
    case SystemState::SLEEP:
      setLeds(false, true, false);
      break;
  }
}

void updateAlertEngine(uint32_t nowMs) {
  if (runStartupSequence(nowMs)) return;
  if (runPiReadyBeepSequence(nowMs)) return;
  if (runDrivingConfirmSequence(nowMs)) return;
  if (runFaceDetectedBeepSequence(nowMs)) {
    if (nowMs < gFaceDetectFlashUntilMs) {
      setLeds(false, true, false);
    } else {
      applyLedsForState();
    }
    return;
  }

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
    gAlarmModeStartMs = nowMs;
    gSleepAlarmCutoffActive = false;
    if (static_cast<int>(gAlertMode) >= static_cast<int>(AlertMode::TIRED_SLOW_BEEP)) {
      gLastAlertEdgeMs = nowMs;
      gLastEspToAlertMs = safeElapsedMs(nowMs, gLastRxMs);
      Serial.print("[ALERT] triggered=");
      Serial.print(static_cast<int>(gAlertMode));
      Serial.print(" prev=");
      Serial.print(static_cast<int>(prevMode));
      Serial.print(" esp_to_alert=");
      Serial.println(gLastEspToAlertMs);
    }
  }

  if (gAlertMode == AlertMode::SLEEP_CONTINUOUS &&
      !gSleepAlarmCutoffActive &&
      safeElapsedMs(nowMs, gAlarmModeStartMs) >= SLEEP_ALARM_MAX_MS) {
    gSleepAlarmCutoffActive = true;
    resetPatternScheduler(nowMs);
    Serial.println("[ALERT] sleep alarm auto-cutoff at 5s");
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
      if (gSleepAlarmCutoffActive) {
        setAlarm(false, 0);
      } else {
        // FIX: sleep alert = continuous beep pattern (beep-beep-beep...), not constant tone lock.
        runSingleBeepPattern(nowMs, 2600, 120, 120);
      }
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

  JsonDocument doc;
  DeserializationError err = deserializeJson(doc, payload);
  if (err) return false;

  bool stateOk = false;
  AiState aiState = AiState::SAFE;
  bool hasNoFace = false;
  bool noFace = false;

  if (doc["status_raw"].is<const char*>()) {
    const char* statusRaw = doc["status_raw"].as<const char*>();
    bool ok = false;
    aiState = mapStatusTextToAiState(statusRaw, &ok);
    stateOk = ok;
    if (ok) {
      hasNoFace = true;
      noFace = equalsIgnoreCase(statusRaw, "NO FACE") || equalsIgnoreCase(statusRaw, "NO_FACE");
    }
  }
  if (!stateOk && doc["status"].is<const char*>()) {
    const char* status = doc["status"].as<const char*>();
    bool ok = false;
    aiState = mapStatusTextToAiState(status, &ok);
    stateOk = ok;
    if (ok) {
      hasNoFace = true;
      noFace = equalsIgnoreCase(status, "NO FACE") || equalsIgnoreCase(status, "NO_FACE");
    }
  }
  if (!stateOk && doc["signal"].is<int>()) {
    aiState = mapSignalToAiState(doc["signal"].as<int>());
    stateOk = true;
  }
  if (!stateOk) return false;

  RxPacket pkt;
  pkt.valid = true;
  pkt.fromMeta = true;
  pkt.aiState = aiState;
  pkt.fatigue = doc["fatigue"].is<int>() ? clampFatigue(doc["fatigue"].as<int>()) : 0;
  pkt.hasNoFace = hasNoFace;
  pkt.noFace = noFace;
  if (doc["face_lock"].is<bool>()) {
    pkt.hasFaceLock = true;
    pkt.faceLock = doc["face_lock"].as<bool>();
  } else if (doc["face_lock"].is<int>()) {
    pkt.hasFaceLock = true;
    pkt.faceLock = (doc["face_lock"].as<int>() != 0);
  }
  if (doc["armed"].is<bool>()) {
    pkt.hasArmed = true;
    pkt.armed = doc["armed"].as<bool>();
  } else if (doc["armed"].is<int>()) {
    pkt.hasArmed = true;
    pkt.armed = (doc["armed"].as<int>() != 0);
  }
  if (doc["arm_progress_pct"].is<int>()) {
    pkt.hasArmProgressPct = true;
    pkt.armProgressPct = clampPercent(doc["arm_progress_pct"].as<int>());
  } else if (doc["arm_progress_pct"].is<unsigned int>()) {
    pkt.hasArmProgressPct = true;
    pkt.armProgressPct = clampPercent(static_cast<int>(doc["arm_progress_pct"].as<unsigned int>()));
  }
  if (doc["arm_remaining_ms"].is<unsigned long>()) {
    pkt.hasArmRemainingMs = true;
    pkt.armRemainingMs = static_cast<uint32_t>(doc["arm_remaining_ms"].as<unsigned long>());
  } else if (doc["arm_remaining_ms"].is<int>()) {
    const int remain = doc["arm_remaining_ms"].as<int>();
    pkt.hasArmRemainingMs = true;
    pkt.armRemainingMs = remain > 0 ? static_cast<uint32_t>(remain) : 0;
  }
  if (doc["pi_ip"].is<const char*>()) {
    const char* piIp = doc["pi_ip"].as<const char*>();
    if (piIp != nullptr && piIp[0] != '\0') {
      const size_t ipLen = strnlen(piIp, sizeof(pkt.piIp));
      if (ipLen > 0 && ipLen < sizeof(pkt.piIp)) {
        memcpy(pkt.piIp, piIp, ipLen);
        pkt.piIp[ipLen] = '\0';
        pkt.hasPiIp = true;
      }
    }
  }

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

    const bool staleGap = safeElapsedMs(nowMs, gLastRxMs) > gCurrentTtlMs;

    if (pkt.hasSeq && gHasSeq && pkt.seq <= gLastSeq) {
      const bool likelyPublisherRestart =
          (pkt.seq < gLastSeq) &&
          (pkt.seq <= 3) &&
          (gLastSeq >= 20);
      if (likelyPublisherRestart) {
        gMetaSessionRestartPending = true;
        resetMetaOrderingState();
      }
      if (!staleGap) return false;
      gMetaSessionRestartPending = true;
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
  if (safeElapsedMs(nowMs, gLastMetaRxMs) <= STATUS_FALLBACK_BLOCK_MS) return false;
  if (pkt.aiState == gLastStatusFallbackAi && safeElapsedMs(nowMs, gLastStatusFallbackMs) < STATUS_DUP_GAP_MS) return false;
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
      gPacketRateHz = (gPacketCountWindow * 1000.0f) / static_cast<float>(elapsed == 0 ? 1U : elapsed);
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
    if (pkt.hasArmed) {
      const bool prevKnown = gPiArmedKnown;
      const bool prevArmed = gPiArmed;
      gPiArmedKnown = true;
      gPiArmed = pkt.armed;
      if ((!prevKnown && gPiArmed) || (prevKnown && !prevArmed && gPiArmed)) {
        gPiArmedRisePending = true;
      }
      if (prevKnown && prevArmed && !gPiArmed && gDrowsyDetectionArmed) {
        resetDrivingArmGateState(nowMs, "pi_gate_off");
      }
    }
    gPiArmProgressKnown = pkt.hasArmProgressPct;
    if (pkt.hasArmProgressPct) {
      gPiArmProgressPct = pkt.armProgressPct;
    }
    gPiArmRemainingKnown = pkt.hasArmRemainingMs;
    if (pkt.hasArmRemainingMs) {
      gPiArmRemainingMs = pkt.armRemainingMs;
    }
    if (pkt.hasPiIp) {
      strncpy(gPiIp, pkt.piIp, sizeof(gPiIp) - 1);
      gPiIp[sizeof(gPiIp) - 1] = '\0';
      gPiIpKnown = true;
    }
    gRawNoFace = pkt.hasNoFace ? pkt.noFace : false;
    gRawFaceLock = pkt.hasFaceLock ? pkt.faceLock : false;
    gLastMetaRxMs = nowMs;

    if (gMetaSessionRestartPending) {
      if (gDrowsyDetectionArmed) {
        resetDrivingArmGateState(nowMs, "publisher_restart");
      }
      resetFaceDetectCueGate(nowMs, "publisher_restart");
      gMetaSessionRestartPending = false;
    }
  } else {
    gLastStatusFallbackAi = pkt.aiState;
    gLastStatusFallbackMs = nowMs;
    gPiArmProgressKnown = false;
    gPiArmRemainingKnown = false;
    gRawNoFace = false;
    gRawFaceLock = false;
  }

  gLastRxMs = nowMs;
  gRawAiState = pkt.aiState;
  gRawFatigue = clampFatigue(pkt.fatigue);
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
    gHasLastSleepTime = true;
    gLastSleepTimeMs = nowMs;
    gSleepAlarmLockUntilMs = nowMs;
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
  uint32_t age = safeElapsedMs(nowMs, gLastRxMs);
  if (age <= gCurrentTtlMs) return;

  if (ENABLE_DRIVING_ARM_GATE && gDrowsyDetectionArmed && age > 12000) {
    resetDrivingArmGateState(nowMs, "stream_stale");
  }

  // FIX #6: hard timeout — if MQTT is dead > 30s, force reset even from
  // dangerous state. Without this, SLEEPY/SLEEP keeps buzzer on forever.
  if (isDangerous(gStableState) && age < WATCHDOG_HARD_TIMEOUT_MS) return;

  bool driving = isDrivingActive();
  setStableState((driving && gDrowsyDetectionArmed) ? SystemState::DRIVING : SystemState::SAFE, nowMs);
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
  JsonDocument doc;
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
  } else if (equalsIgnoreCase(action, "set_broker")) {
    const char* host = doc["host"].as<const char*>();
    uint16_t port = doc["port"].is<uint16_t>() ? doc["port"].as<uint16_t>() : MQTT_PORT_DEFAULT;
    if (host == nullptr || host[0] == '\0') {
      Serial.println("[CMD] set_broker missing host");
      return;
    }
    applyMqttBroker(host, port, true, "mqtt_cmd");
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
    {
    const uint32_t sampleCount = (gLatencySamples == 0) ? 1U : gLatencySamples;
    gLatencyAvgMs += (static_cast<float>(gLastLatencyTotalMs) - gLatencyAvgMs) / static_cast<float>(sampleCount);
  }
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
  bool driving = isDrivingActive();
  SystemState observed = deriveObservedState(pkt.aiState, driving, gDrowsyDetectionArmed, gRawNoFace);
  applyObservation(observed, nowMs);
}

void ensureMqtt(uint32_t nowMs) {
  if (!gWifiManager.isConnected()) {
    // FIX: force MQTT reset immediately when WiFi is not in connected state.
    if (gMqttTcpConnected) {
      gMqtt.disconnect();
    }
    gMqttTcpConnected = false;
    gMqttUp = false;
    gMqttSubscribed = false;
    gFirstPacketReceived = false;
    gPiIpKnown = false;
    gPiIp[0] = '\0';
    gNeedSyncAfterReconnect = true;
    return;
  }

  if (gMqttTcpConnected) {
    // FIX: recover from half-connected state by retrying subscribe non-blocking.
    if (!gMqttSubscribed && nowMs >= gNextSubTryMs) {
      if (subscribeTopics()) {
        gMqttSubscribed = true;
        gMqttUp = true;
        gNeedSyncAfterReconnect = true;
        gFirstPacketReceived = false;
        gPiIpKnown = false;
        gPiIp[0] = '\0';
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
    bool packetFresh = safeElapsedMs(nowMs, gLastRxMs) <= MQTT_SYNC_FRESH_MS;
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
    gMqttTcpConnected = true;
    gReconnectCount++;
    gNeedSyncAfterReconnect = true;
    gFirstPacketReceived = false;
    gPiIpKnown = false;
    gPiIp[0] = '\0';
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

  gMqttTcpConnected = false;
  gMqttUp = false;
  gMqttSubscribed = false;
  gFirstPacketReceived = false;
  gPiIpKnown = false;
  gPiIp[0] = '\0';
  gMqttRetryCount++;
  if (gMqttRetryCount > MQTT_RETRY_LIMIT) {
    gMqttRetryCount = 0;
    gMqttBackoffMs = min(gMqttBackoffMs * 2U, MQTT_BACKOFF_CAP_MS);
  }
  gNextMqttTryMs = nowMs + gMqttBackoffMs;
  if (safeElapsedMs(nowMs, gLastMqttRetryLogMs) >= 1000) {
    gLastMqttRetryLogMs = nowMs;
    Serial.print("MQTT retry in ms=");
    Serial.print(gNextMqttTryMs - nowMs);
    Serial.print(" state=");
    Serial.println(gMqtt.state());
  }
}

void processConnectivity(uint32_t nowMs) {
  gWifiManager.tick(nowMs);
  ensureMqtt(nowMs);

  if (gMqttTcpConnected) {
    const bool loopOk = gMqtt.loop();
    if (!loopOk) {
      gMqttTcpConnected = false;
      gMqttUp = false;
      gMqttSubscribed = false;
      gFirstPacketReceived = false;
      gPiIpKnown = false;
      gPiIp[0] = '\0';
    }
  }

  bool mqttConnected = gMqttTcpConnected;
  if (gPrevMqttConnected && !mqttConnected) {
    gMqttUp = false;
    gMqttSubscribed = false;
    gFirstPacketReceived = false;
    gPiIpKnown = false;
    gPiIp[0] = '\0';
    resetDrivingArmGateState(nowMs, "mqtt_down");
    Serial.println("MQTT DOWN");
  }
  gPrevMqttConnected = mqttConnected;
}

void publishEspTelemetry(uint32_t nowMs) {
  if (!gMqttTcpConnected || !gMqttUp) return;
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
      isDrivingActive() ? "true" : "false",
      gMqttTcpConnected ? "UP" : "DOWN",
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
  gOledStatus.begin(millis());

  loadMqttBrokerConfig();
  gWifiManager.begin("DrowsySetup");
  Serial.println("[CFG] WiFi requireInternet=false healthHost=raspberrypi.local:1883");
  Serial.println("[CFG] Motion threshold=0.08 persist=2000ms hold=2500ms");
  Serial.print("[CFG] MQTT broker=");
  Serial.print(gMqttHost);
  Serial.print(":");
  Serial.println(gMqttPort);
  bool motionOk = gMotionDetector.begin();
  Serial.print("MPU6050 available=");
  Serial.println(motionOk ? "yes" : "no");

  gMqtt.setServer(gMqttHost, gMqttPort);
  gMqtt.setKeepAlive(20);
  gMqtt.setSocketTimeout(3);
  gMqtt.setBufferSize(420);
  gMqtt.setCallback(onMqttMessage);

  if (!ENABLE_DRIVING_ARM_GATE) {
    Serial.println("[CFG] Driving arm gate=OFF (Pi state drives alert directly)");
  } else {
    Serial.println("[CFG] Driving arm gate=ON (5s attentive required)");
  }
  Serial.print("[CFG] Startup beep on boot=");
  Serial.println(ENABLE_STARTUP_BEEP_ON_BOOT ? "ON" : "OFF");
  Serial.print("[CFG] Pi ready beep=");
  Serial.println(ENABLE_PI_READY_BEEP ? "ON" : "OFF");
  Serial.print("[CFG] OLED status display=");
  Serial.println(gOledStatus.available() ? "ON" : "OFF");

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
  gPiIpKnown = false;
  gPiIp[0] = '\0';
  gPacketRateMarkMs = nowMs;
  gAttentivePauseAccumMs = 0;
}

void loop() {
  uint32_t nowMs = millis();

  pollSerialControl();
  gMotionDetector.tick(nowMs);
  checkWifiResetButton(nowMs);  // Method A: long-press button check
  processConnectivity(nowMs);
  nowMs = millis();  // FIX: refresh after MQTT callback side-effects on timestamps.
  updateDrivingArmGate(nowMs);
  updatePiReadyBeepTrigger(nowMs);
  updateFaceDetectedBeepTrigger(nowMs);

  // Keep DRIVING/SAFE aligned with motion when AI is SAFE.
  if (safeElapsedMs(nowMs, gLastRxMs) <= gCurrentTtlMs && gRawAiState == AiState::SAFE) {
    const bool allowDriveState = isDrivingActive() && (!ENABLE_DRIVING_ARM_GATE || gDrowsyDetectionArmed);
    SystemState idleState = allowDriveState ? SystemState::DRIVING : SystemState::SAFE;
    if (idleState != gObservedState) {
      applyObservation(idleState, nowMs);
    }
  }

  applyDataWatchdog(nowMs);
  updateConfirmedState(nowMs);
  updateAlertEngine(nowMs);
  updateOledWarnings(nowMs);
  updateOledStatus(nowMs);
  publishEspTelemetry(nowMs);

  if ((nowMs - gLastLogMs) >= LOG_GAP_MS) {
    gLastLogMs = nowMs;
    // QW1: consolidated from 35 Serial.print calls (~24ms) into single snprintf (~3ms)
    char logBuf[420];
    snprintf(logBuf, sizeof(logBuf),
      "W:%s P:%s M:%s MU:%s PK:%s PA:%s/%s ARM:%s AI:%s NF:%s FL:%s O:%s S:%s C:%s D:%s V:%.3f A:%d(%s) T:%lu R:%lu L:%lu Hz:%.1f X:%lu RC:%lu F:%d",
      gWifiManager.isConnected() ? "OK" : "DN",
      gWifiManager.portalActive() ? "ON" : "--",
      gMqttTcpConnected ? "OK" : "DN",
      gMqttUp ? "Y" : "N",
      gFirstPacketReceived ? "Y" : "N",
      gPiArmedKnown ? "Y" : "N",
      gPiArmed ? "Y" : "N",
      gDrowsyDetectionArmed ? "Y" : "N",
      aiStateName(gRawAiState),
      gRawNoFace ? "Y" : "N",
      gRawFaceLock ? "Y" : "N",
      systemStateName(gObservedState),
      systemStateName(gStableState),
      systemStateName(gConfirmedState),
      isDrivingActive() ? "Y" : "N",
      static_cast<double>(gMotionDetector.vibrationLevel()),
      static_cast<int>(gAlertMode),
      alertModeName(gAlertMode),
      static_cast<unsigned long>(gCurrentTtlMs),
      static_cast<unsigned long>(safeElapsedMs(nowMs, gLastRxMs)),
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
